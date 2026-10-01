// A static file server for WebGL builds: node serve.mjs <dir> [port]  (used by `velo run webgl`).
// It also tells open pages to reload when the build changes (Server-Sent Events on /__velo_events).
import { createServer } from 'node:http'
import { watchFile } from 'node:fs'
import { readFile, stat } from 'node:fs/promises'
import { extname, join, normalize, resolve } from 'node:path'

const root = resolve(process.argv[2] ?? '.')
const port = Number(process.argv[3] ?? 8080)
const types = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.mjs': 'text/javascript; charset=utf-8',
	'.map': 'application/json',
	'.json': 'application/json',
	'.css': 'text/css',
	'.png': 'image/png',
	'.jpg': 'image/jpeg',
	'.jpeg': 'image/jpeg',
	'.bmp': 'image/bmp',
	'.wav': 'audio/wav',
	'.ogg': 'audio/ogg',
	'.mp3': 'audio/mpeg',
	'.ttf': 'font/ttf',
	'.otf': 'font/otf',
	'.txt': 'text/plain; charset=utf-8',
	'.scene': 'text/plain; charset=utf-8',
	'.prefab': 'text/plain; charset=utf-8',
}

// pages built by `velo run webgl` listen here and reload when velo writes a new .velo-version
const clients = new Set()
watchFile(join(root, '.velo-version'), { interval: 300 }, () => {
	for (const res of clients) res.write('data: reload\n\n')
})

createServer(async (req, res) => {
	try {
		const url = new URL(req.url ?? '/', 'http://localhost')
		if (url.pathname === '/__velo_events') {
			res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' })
			res.write(': connected\n\n')
			clients.add(res)
			req.on('close', () => clients.delete(res))
			return
		}
		let path = normalize(join(root, decodeURIComponent(url.pathname)))
		if (!path.startsWith(root)) throw new Error('outside the root')
		if ((await stat(path)).isDirectory()) path = join(path, 'index.html')
		const body = await readFile(path)
		res.writeHead(200, { 'content-type': types[extname(path).toLowerCase()] ?? 'application/octet-stream', 'cache-control': 'no-cache' })
		res.end(body)
	} catch {
		res.writeHead(404, { 'content-type': 'text/plain' })
		res.end('not found')
	}
}).listen(port, () => console.log(`serving ${root} on http://localhost:${port}/`))
