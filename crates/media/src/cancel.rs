//! Cooperative cancellation of frame requests.
//!
//! A frame worker runs a job inside [`with_cancel`]; sources that do long work for a request (a
//! decoder seeking back to a keyframe and decoding forward) poll [`cancelled`] and give up with
//! [`MediaError::Cancelled`](crate::MediaError::Cancelled) once the job is no longer wanted, e.g.
//! playback has moved past its frame. The flag travels through a thread-local, so the
//! [`MediaSource`](crate::MediaSource) API is unchanged.
//!
//! The same way, [`with_catch_up`] tells sources which frames before the requested one are late
//! (playback has passed them): a decoder that has to decode forward to the frame may skip
//! pictures that only produce late frames and that nothing else references.
//!
//! [`with_draft`] marks reduced-resolution playback (opt-in): decoders may take spec-safe
//! shortcuts that only change pictures nothing references (H.264: no deblocking of non-reference
//! pictures). Never set for exports, renders or a frame shown while paused.
//!
//! [`with_background`] marks work nobody waits on interactively (thumbnails of the Project panel,
//! the Media Browser and the timeline): sources should not keep expensive state, such as a
//! frame-threaded 4K decoder, for it once it is done.

use std::cell::{Cell, RefCell};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use filmcraft_time::Tick;

thread_local! {
    static CURRENT: RefCell<Option<Arc<AtomicBool>>> = const { RefCell::new(None) };
    static CATCH_UP: Cell<Option<Tick>> = const { Cell::new(None) };
    static DRAFT: Cell<bool> = const { Cell::new(false) };
    static BACKGROUND: Cell<bool> = const { Cell::new(false) };
}

/// Run `f` as background work when `on` (restoring the previous hint after): a thumbnail, not a
/// frame a monitor or playback waits for.
pub fn with_background<R>(on: bool, f: impl FnOnce() -> R) -> R {
    /// Restores the previous hint however `f` ends (a panic caught further up must not leave the
    /// worker thread marked as background).
    struct Restore(bool);
    impl Drop for Restore {
        fn drop(&mut self) {
            BACKGROUND.with(|c| c.set(self.0));
        }
    }
    let _restore = Restore(BACKGROUND.with(|c| c.replace(on)));
    f()
}

/// Whether the work running on this thread is background work (off unless inside
/// [`with_background`]`(true, …)`).
pub fn background() -> bool {
    BACKGROUND.with(Cell::get)
}

/// Restores a thread-local `Cell` hint when dropped, so the previous value comes back even when
/// the scoped closure panics: a leaked `DRAFT = true` on a reused worker thread would otherwise
/// make a later export decode in draft quality.
struct RestoreCell<T: Copy + 'static> {
    key: &'static std::thread::LocalKey<Cell<T>>,
    prev: T,
}

impl<T: Copy + 'static> Drop for RestoreCell<T> {
    fn drop(&mut self) {
        // `try_with`: during thread teardown the key may already be gone.
        let _ = self.key.try_with(|c| c.set(self.prev));
    }
}

/// Restores the thread's cancellation flag when dropped (also while unwinding).
struct RestoreCancel(Option<Arc<AtomicBool>>);

impl Drop for RestoreCancel {
    fn drop(&mut self) {
        let prev = self.0.take();
        let _ = CURRENT.try_with(|c| *c.borrow_mut() = prev);
    }
}

/// Run `f` with the draft-decoding hint `on` (restoring the previous one after, even if `f`
/// panics). Frames decoded in draft mode are only handed to requests made in draft mode.
pub fn with_draft<R>(on: bool, f: impl FnOnce() -> R) -> R {
    let _restore = RestoreCell { key: &DRAFT, prev: DRAFT.with(|c| c.replace(on)) };
    f()
}

/// Whether the work running on this thread accepts draft-quality decoding (off unless inside
/// [`with_draft`]`(true, …)`).
pub fn draft() -> bool {
    DRAFT.with(Cell::get)
}

/// Run `f` with the catch-up hint `margin` (restoring the previous one after, even if `f` panics): frames shown more
/// than `margin` before the requested time are late (`Some(Tick::ZERO)`: everything before it).
/// The margin is measured in media time at normal speed; a wrong guess (a sped-up or reversed
/// clip) only costs a later re-seek, never a wrong frame.
pub fn with_catch_up<R>(margin: Option<Tick>, f: impl FnOnce() -> R) -> R {
    let _restore = RestoreCell { key: &CATCH_UP, prev: CATCH_UP.with(|c| c.replace(margin)) };
    f()
}

/// The catch-up margin of the work running on this thread (None: no frame is late).
pub fn catch_up() -> Option<Tick> {
    CATCH_UP.with(Cell::get)
}

/// Run `f` with `flag` as this thread's cancellation flag (restoring the previous one after,
/// even if `f` panics).
pub fn with_cancel<R>(flag: &Arc<AtomicBool>, f: impl FnOnce() -> R) -> R {
    let _restore = RestoreCancel(CURRENT.with(|c| c.replace(Some(flag.clone()))));
    f()
}

/// Whether the work running on this thread has been cancelled.
pub fn cancelled() -> bool {
    CURRENT.with(|c| c.borrow().as_ref().is_some_and(|f| f.load(Ordering::Relaxed)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flag_is_scoped_to_the_closure() {
        let flag = Arc::new(AtomicBool::new(false));
        assert!(!cancelled());
        with_cancel(&flag, || {
            assert!(!cancelled());
            flag.store(true, Ordering::Relaxed);
            assert!(cancelled());
        });
        assert!(!cancelled());
    }

    #[test]
    fn a_panic_inside_a_scope_does_not_leak_the_hints_to_the_next_job() {
        use std::panic::{AssertUnwindSafe, catch_unwind};
        let flag = Arc::new(AtomicBool::new(true));
        let outcome = catch_unwind(AssertUnwindSafe(|| {
            with_draft(true, || {
                with_catch_up(Some(Tick(9)), || {
                    with_cancel(&flag, || panic!("decoder blew up"));
                })
            })
        }));
        assert!(outcome.is_err());
        assert!(!draft());
        assert_eq!(catch_up(), None);
        assert!(!cancelled());
    }

    #[test]
    fn draft_is_off_by_default_and_scoped() {
        assert!(!draft());
        with_draft(true, || {
            assert!(draft());
            with_draft(false, || assert!(!draft()));
            assert!(draft());
        });
        assert!(!draft());
    }

    #[test]
    fn background_is_off_by_default_and_scoped() {
        assert!(!background());
        with_background(true, || {
            assert!(background());
            with_background(false, || assert!(!background()));
            assert!(background());
        });
        assert!(!background());
    }

    #[test]
    fn a_panic_inside_background_work_does_not_leave_the_thread_marked() {
        let r = std::panic::catch_unwind(|| with_background(true, || panic!("boom")));
        assert!(r.is_err());
        assert!(!background());
    }

    #[test]
    fn catch_up_is_scoped_to_the_closure() {
        assert_eq!(catch_up(), None);
        with_catch_up(Some(Tick(5)), || {
            assert_eq!(catch_up(), Some(Tick(5)));
            with_catch_up(None, || assert_eq!(catch_up(), None));
            assert_eq!(catch_up(), Some(Tick(5)));
        });
        assert_eq!(catch_up(), None);
    }
}
