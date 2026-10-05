module websocket

// A websocket client that polls instead of calling back: connect(), then state() / poll() / send() every frame.
// It exists for the WebGL build (`velo build webgl`), where it is the browser's WebSocket (webgl/runtime/websocket.ts);
// the browser has no threads, and V's net.websocket cannot be translated. On desktop use net.websocket in its own
// thread (see examples of a client that does so); here connect() just fails.

pub enum State {
	connecting
	open
	closed
	failed
}

@[heap]
pub struct Socket {
mut:
	st    State = .failed
	err   string
	inbox []string
}

// connect starts connecting and returns at once; state() becomes .open, or .failed with error() set.
pub fn connect(url string) &Socket {
	return &Socket{
		err: 'websocket.connect is only available in the WebGL build'
	}
}

pub fn (s &Socket) state() State {
	return s.st
}

pub fn (s &Socket) error() string {
	return s.err
}

// send writes one text message (ignored while not open).
pub fn (mut s Socket) send(text string) {
}

// poll returns the text messages that arrived since the last call.
pub fn (mut s Socket) poll() []string {
	out := s.inbox.clone()
	s.inbox.clear()
	return out
}

pub fn (mut s Socket) close() {
	s.st = .closed
}
