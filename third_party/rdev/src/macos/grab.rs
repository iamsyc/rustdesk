#![allow(improper_ctypes_definitions)]
use crate::macos::common::*;
use crate::rdev::{Event, GrabError};
use cocoa::base::nil;
use cocoa::foundation::NSAutoreleasePool;
use core_graphics::event::{CGEventTapLocation, CGEventType};
use std::os::raw::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};

static mut GLOBAL_CALLBACK: Option<Box<dyn FnMut(Event) -> Option<Event>>> = None;
static EVENT_TAP: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

#[inline]
fn is_tap_disabled(event_type: CGEventType) -> bool {
    matches!(
        event_type,
        CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput
    )
}

unsafe extern "C" fn raw_callback(
    _proxy: CGEventTapProxy,
    _type: CGEventType,
    cg_event: CGEventRef,
    _user_info: *mut c_void,
) -> CGEventRef {
    if is_tap_disabled(_type) {
        let tap = EVENT_TAP.load(Ordering::Acquire) as CFMachPortRef;
        if tap.is_null() {
            log::error!(
                "macOS keyboard event tap was disabled ({:?}), but its handle is unavailable",
                _type
            );
        } else {
            CGEventTapEnable(tap, true);
            log::warn!(
                "macOS keyboard event tap was disabled ({:?}) and has been re-enabled",
                _type
            );
        }
        return cg_event;
    }

    // println!("Event ref {:?}", cg_event_ptr);
    // let cg_event: CGEvent = transmute_copy::<*mut c_void, CGEvent>(&cg_event_ptr);
    if let Ok(mut state) = KEYBOARD_STATE.lock() {
        if let Some(keyboard) = state.as_mut() {
            if let Some(event) = convert(_type, &cg_event, keyboard) {
                if let Some(callback) = &mut GLOBAL_CALLBACK {
                    if callback(event).is_none() {
                        cg_event.set_type(CGEventType::Null);
                    }
                }
            }
        }
    }
    cg_event
}

static mut CUR_LOOP: CFRunLoopSourceRef = std::ptr::null_mut();

#[inline]
pub fn is_grabbed() -> bool {
    unsafe { !CUR_LOOP.is_null() }
}

pub fn grab<T>(callback: T) -> Result<(), GrabError>
where
    T: FnMut(Event) -> Option<Event> + 'static,
{
    if is_grabbed() {
        return Ok(());
    }

    unsafe {
        GLOBAL_CALLBACK = Some(Box::new(callback));
        let _pool = NSAutoreleasePool::new(nil);
        let tap = CGEventTapCreate(
            CGEventTapLocation::Session, // HID, Session, AnnotatedSession,
            kCGHeadInsertEventTap,
            CGEventTapOption::Default,
            kCGEventMaskForAllEvents,
            raw_callback,
            nil,
        );
        if tap.is_null() {
            return Err(GrabError::EventTapError);
        }
        let _loop = CFMachPortCreateRunLoopSource(nil, tap, 0);
        if _loop.is_null() {
            return Err(GrabError::LoopSourceError);
        }

        CUR_LOOP = CFRunLoopGetCurrent() as _;
        CFRunLoopAddSource(CUR_LOOP, _loop, kCFRunLoopCommonModes);

        EVENT_TAP.store(tap as *mut c_void, Ordering::Release);
        CGEventTapEnable(tap, true);
        CFRunLoopRun();
        EVENT_TAP.store(std::ptr::null_mut(), Ordering::Release);
    }
    Ok(())
}

pub fn exit_grab() -> Result<(), GrabError> {
    unsafe {
        let tap = EVENT_TAP.swap(std::ptr::null_mut(), Ordering::AcqRel) as CFMachPortRef;
        if !tap.is_null() {
            CGEventTapEnable(tap, false);
        }
        if !CUR_LOOP.is_null() {
            CFRunLoopStop(CUR_LOOP);
            CUR_LOOP = std::ptr::null_mut();
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_event_tap_disable_notifications() {
        assert!(is_tap_disabled(CGEventType::TapDisabledByTimeout));
        assert!(is_tap_disabled(CGEventType::TapDisabledByUserInput));
        assert!(!is_tap_disabled(CGEventType::KeyDown));
    }
}
