use super::Decoder;
use crate::ffmpeg_ram::ffmpeg_ram_decode_native;
use std::{ffi::c_void, os::raw::c_int};

extern "C" {
    fn CFRetain(value: *const c_void) -> *const c_void;
    fn CFRelease(value: *const c_void);
}

/// An immutable decoded CVPixelBuffer, retained independently of FFmpeg's next frame.
pub struct NativeFrame {
    buffer: *mut c_void,
    pub width: i32,
    pub height: i32,
}

// Core Video's retain/release operations are thread safe; published frames are immutable.
unsafe impl Send for NativeFrame {}
unsafe impl Sync for NativeFrame {}

impl NativeFrame {
    pub fn as_ptr(&self) -> *mut c_void {
        self.buffer
    }
}

impl Clone for NativeFrame {
    fn clone(&self) -> Self {
        unsafe {
            CFRetain(self.buffer);
        }
        Self {
            buffer: self.buffer,
            width: self.width,
            height: self.height,
        }
    }
}

impl Drop for NativeFrame {
    fn drop(&mut self) {
        unsafe {
            CFRelease(self.buffer);
        }
    }
}

struct Output {
    frame: Option<NativeFrame>,
    invalid: bool,
}

unsafe extern "C" fn retain_frame(
    obj: *const c_void,
    width: c_int,
    height: c_int,
    _pixfmt: c_int,
    _linesizes: *mut c_int,
    datas: *mut *mut u8,
    _key: c_int,
) {
    let output = &mut *(obj as *mut Output);
    if width <= 0 || height <= 0 || (*datas.add(3)).is_null() {
        output.invalid = true;
        return;
    }
    let buffer = *datas.add(3) as *mut c_void;
    CFRetain(buffer);
    output.frame = Some(NativeFrame {
        buffer,
        width,
        height,
    });
}

impl Decoder {
    pub fn decode_native(&mut self, packet: &[u8]) -> Result<Option<NativeFrame>, i32> {
        let mut output = Output {
            frame: None,
            invalid: false,
        };
        let ret = unsafe {
            ffmpeg_ram_decode_native(
                self.codec,
                packet.as_ptr(),
                packet.len() as c_int,
                &mut output as *mut _ as *const c_void,
                Some(retain_frame),
            )
        };
        if ret < 0 {
            Err(ret)
        } else if output.invalid {
            Err(-1)
        } else {
            Ok(output.frame)
        }
    }
}
