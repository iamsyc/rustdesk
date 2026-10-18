use std::{ops, ptr, slice};

use super::ffi::*;

pub struct Frame {
    surface: IOSurfaceRef,
    inner: &'static [u8],
    bgra: &'static [u8],
    bgra_stride: usize,
}

impl Frame {
    pub unsafe fn new(surface: IOSurfaceRef) -> Frame {
        CFRetain(surface);
        IOSurfaceIncrementUseCount(surface);

        IOSurfaceLock(surface, SURFACE_LOCK_READ_ONLY, ptr::null_mut());

        let inner = slice::from_raw_parts(
            IOSurfaceGetBaseAddress(surface) as *const u8,
            IOSurfaceGetAllocSize(surface),
        );

        Frame {
            surface,
            inner,
            bgra: &[],
            bgra_stride: 0,
        }
    }

    #[inline]
    pub fn inner(&self) -> &[u8] {
        self.inner
    }

    pub fn stride(&self) -> usize {
        self.bgra_stride
    }

    pub fn map_bgra(&mut self, h: usize) {
        unsafe {
            let plane0 = IOSurfaceGetBaseAddressOfPlane(self.surface, 0);
            self.bgra_stride = IOSurfaceGetBytesPerRowOfPlane(self.surface, 0);
            // The surface stays retained and read-locked until this frame is dropped.
            self.bgra = slice::from_raw_parts(plane0 as _, self.bgra_stride * h);
        }
    }
}

impl ops::Deref for Frame {
    type Target = [u8];
    fn deref<'a>(&'a self) -> &'a [u8] {
        self.bgra
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        unsafe {
            IOSurfaceUnlock(self.surface, SURFACE_LOCK_READ_ONLY, ptr::null_mut());

            IOSurfaceDecrementUseCount(self.surface);
            CFRelease(self.surface);
        }
    }
}
