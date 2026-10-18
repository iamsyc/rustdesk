use super::*;

type Completion = extern "C" fn(i32, u64, bool, bool);
type Publish = unsafe extern "C" fn(*mut c_void, *mut c_void, i32, Completion) -> i32;

extern "C" fn completed(display: i32, ready_us: u64, published: bool, success: bool) {
    if !success {
        hbb_common::throttled_log!(
            std::time::Duration::from_secs(5),
            warn,
            "Native pixel-buffer publication failed"
        );
    }
    log::trace!("native_pixelbuffer_ready display={display} ready_us={ready_us} published={published}");
}

lazy_static::lazy_static! {
    static ref PUBLISH: Option<Symbol<'static, Publish>> = {
        match &*TEXTURE_RGBA_RENDERER_PLUGIN {
            Ok(lib) => match unsafe { lib.symbol::<Publish>("FlutterRgbaRendererPluginOnPixelBuffer") } {
                Ok(symbol) => Some(symbol),
                Err(e) => { log::error!("Missing native pixel-buffer renderer: {e}"); None }
            },
            Err(e) => { log::error!("Cannot load native pixel-buffer renderer: {e}"); None }
        }
    };
}

impl VideoRenderer {
    pub(super) fn on_macos_pixelbuffer(&self, display: usize, rgba: &scrap::ImageRgb) -> bool {
        let Some(frame) = &rgba.native else {
            return false;
        };
        let Some(publish) = PUBLISH.as_ref() else {
            return false;
        };
        let mut sessions = self.map_display_sessions.write().unwrap();
        let info = if self.is_support_multi_ui_session {
            sessions.get_mut(&display)
        } else {
            sessions.values_mut().next()
        };
        let Some(info) = info else { return false };
        if info.texture_rgba_ptr == 0 || (info.size != (0, 0) && info.size != (rgba.w, rgba.h)) {
            return false;
        }
        let status = unsafe {
            publish(
                info.texture_rgba_ptr as _,
                frame.as_ptr(),
                display as _,
                completed,
            )
        };
        if status == 0 {
            hbb_common::throttled_log!(
                std::time::Duration::from_secs(5),
                warn,
                "Native pixel-buffer rendering failed"
            );
            return false;
        }
        if status != 1 {
            return false;
        }
        if info.notify_render_type != Some(RenderType::PixelBuffer) {
            info.notify_render_type = Some(RenderType::PixelBuffer);
            true
        } else {
            false
        }
    }
}
