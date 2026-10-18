pub(super) fn trace_uptime() -> Option<f64> {
    use hbb_common::libc::{clock_gettime, timespec, CLOCK_UPTIME_RAW};

    // Match Core Animation and Metal timestamps without wall-clock corrections.
    let mut time = timespec { tv_sec: 0, tv_nsec: 0 };
    if unsafe { clock_gettime(CLOCK_UPTIME_RAW, &mut time) } == 0 {
        Some(time.tv_sec as f64 + time.tv_nsec as f64 * 1e-9)
    } else {
        None
    }
}

// Observe framing backlog without logging message contents or transport keys.
pub(super) fn trace_io(stage: &str, peer: &hbb_common::Stream) {
    hbb_common::log::trace!(
        "client_io stage={stage} tcp_buffer={:?} monotonic={:?}",
        match peer {
            hbb_common::Stream::Tcp(stream) => Some(stream.read_buffer().len()),
            _ => None,
        },
        trace_uptime(),
    );
}

pub(super) fn coalesce_hover(
    mut current: super::Data,
    receiver: &mut hbb_common::tokio::sync::mpsc::UnboundedReceiver<super::Data>,
    pending: &mut Option<super::Data>,
) -> super::Data {
    use super::Data;
    use base::message_proto::message::Union;

    let Data::Message(message) = &current else {
        return current;
    };
    let Some(Union::MouseEvent(mouse)) = &message.union else {
        return current;
    };
    if mouse.mask != 0 {
        return current;
    }

    while let Ok(next) = receiver.try_recv() {
        let merge = match (&current, &next) {
            (Data::Message(a), Data::Message(b)) => match (&a.union, &b.union) {
                (Some(Union::MouseEvent(a)), Some(Union::MouseEvent(b))) => {
                    b.mask == 0 && a.modifiers == b.modifiers
                }
                _ => false,
            },
            _ => false,
        };
        if !merge {
            *pending = Some(next);
            break;
        }
        current = next;
    }
    current
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{ControlKey, Message, MouseEvent};
    use hbb_common::tokio::sync::mpsc::unbounded_channel;

    fn mouse(mask: i32, x: i32, shift: bool) -> super::super::Data {
        let mut event = MouseEvent {
            mask,
            x,
            ..Default::default()
        };
        if shift {
            event.modifiers.push(ControlKey::Shift.into());
        }
        let mut message = Message::new();
        message.set_mouse_event(event);
        super::super::Data::Message(message)
    }

    fn values(data: super::super::Data) -> (i32, i32) {
        match data {
            super::super::Data::Message(message) => {
                (message.mouse_event().mask, message.mouse_event().x)
            }
            _ => panic!("expected mouse message"),
        }
    }

    #[test]
    fn hover_backlog_keeps_latest_before_click() {
        let (tx, mut rx) = unbounded_channel();
        for x in 1..=24 {
            tx.send(mouse(0, x, false)).unwrap();
        }
        tx.send(mouse(9, 0, false)).unwrap();
        tx.send(mouse(8, 25, false)).unwrap();
        tx.send(mouse(10, 0, false)).unwrap();
        let mut pending = None;
        let first = rx.try_recv().unwrap();
        assert_eq!(
            values(coalesce_hover(first, &mut rx, &mut pending)),
            (0, 24)
        );
        assert_eq!(values(pending.take().unwrap()), (9, 0));
        assert_eq!(values(rx.try_recv().unwrap()), (8, 25));
        assert_eq!(values(rx.try_recv().unwrap()), (10, 0));
    }

    #[test]
    fn drag_relative_scroll_and_modifier_changes_are_not_merged() {
        for mask in [8, 5, 3, 4] {
            let (tx, mut rx) = unbounded_channel();
            tx.send(mouse(mask, 2, false)).unwrap();
            let mut pending = None;
            assert_eq!(
                values(coalesce_hover(mouse(mask, 1, false), &mut rx, &mut pending)),
                (mask, 1)
            );
            assert_eq!(values(rx.try_recv().unwrap()), (mask, 2));
        }
        let (tx, mut rx) = unbounded_channel();
        tx.send(mouse(0, 2, true)).unwrap();
        let mut pending = None;
        assert_eq!(
            values(coalesce_hover(mouse(0, 1, false), &mut rx, &mut pending)),
            (0, 1)
        );
        assert_eq!(values(pending.take().unwrap()), (0, 2));
    }

    #[test]
    fn video_ack_is_opt_in_for_desktop_only() {
        use super::super::LoginConfigHandler;
        use base::config::keys;
        use hbb_common::rendezvous_proto::ConnType;
        let mut config = LoginConfigHandler::default();
        let asks = |config: &LoginConfigHandler| {
            config.create_login_msg(String::new(), String::new(), vec![])
                .login_request().video_ack_required
        };
        assert!(!asks(&config));
        config.config.options.insert(keys::OPTION_VIDEO_ACK_REQUIRED.into(), "Y".into());
        assert!(asks(&config));
        config.conn_type = ConnType::FILE_TRANSFER;
        assert!(!asks(&config));
    }

    #[test]
    fn hover_backlog_preserves_keyboard_order() {
        use base::message_proto::KeyEvent;
        let (tx, mut rx) = unbounded_channel();
        tx.send(mouse(0, 2, false)).unwrap();
        for down in [true, false] {
            let mut event = KeyEvent::new();
            event.down = down;
            event.set_chr(0);
            let mut message = Message::new();
            message.set_key_event(event);
            tx.send(super::super::Data::Message(message)).unwrap();
        }
        let mut pending = None;
        assert_eq!(values(coalesce_hover(mouse(0, 1, false), &mut rx, &mut pending)), (0, 2));
        for (data, down) in [(pending.take().unwrap(), true), (rx.try_recv().unwrap(), false)] {
            let super::super::Data::Message(message) = data else { panic!("expected key") };
            assert_eq!(message.key_event().down, down);
        }
    }

    #[test]
    fn a_single_hover_is_sent_immediately() {
        let (_tx, mut rx) = unbounded_channel();
        let mut pending = None;
        assert_eq!(
            values(coalesce_hover(mouse(0, 1, false), &mut rx, &mut pending)),
            (0, 1)
        );
        assert!(pending.is_none());
    }
}
