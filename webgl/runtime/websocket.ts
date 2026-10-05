// websocket: the browser's WebSocket behind the polling API of websocket/websocket.v.

export type State = 'connecting' | 'open' | 'closed' | 'failed'

export class Socket {
	static __vname = 'websocket.Socket'
	st: State = 'connecting'
	err = ''
	inbox: string[] = []
	private sock: WebSocket | null = null

	constructor(url = '') {
		if (url === '') {
			return
		}
		try {
			const s = new WebSocket(url)
			this.sock = s
			s.onopen = () => {
				this.st = 'open'
			}
			s.onmessage = (ev) => {
				if (typeof ev.data === 'string') {
					this.inbox.push(ev.data)
				}
			}
			s.onerror = () => {
				if (this.st === 'connecting') {
					this.st = 'failed'
					this.err = `cannot connect to ${url}`
				}
			}
			s.onclose = () => {
				if (this.st === 'open') {
					this.st = 'closed'
				} else if (this.st === 'connecting') {
					this.st = 'failed'
					this.err = this.err || `cannot connect to ${url}`
				}
			}
		} catch (e) {
			this.st = 'failed'
			this.err = `${(e as Error).message}`
		}
	}
	state(): State {
		return this.st
	}
	error(): string {
		return this.err
	}
	send(text: string) {
		if (this.sock && this.st === 'open') {
			this.sock.send(text)
		}
	}
	poll(): string[] {
		const out = this.inbox
		this.inbox = []
		return out
	}
	close() {
		if (this.sock) {
			this.sock.onclose = null
			this.sock.close(1000, 'bye')
			this.sock = null
		}
		this.st = 'closed'
	}
}

export function connect(url: string): Socket {
	return new Socket(url)
}
