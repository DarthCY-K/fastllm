import json, time, uuid, zlib, struct, base64, urllib.request

BASE = 'http://127.0.0.1:8081/v1/chat/completions'
ENV = '/home/ai-agent/qwen38-0.2x.env'

key = None
for line in open(ENV):
    line = line.strip()
    if line.startswith('VLLM_API_KEY='):
        key = line.split('=', 1)[1].strip()
assert key, 'no key found'

def png_dataurl(color=b'\xff\x00\x00', w=16, h=16):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    raw = b''.join(b'\x00' + color * w for _ in range(h))
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw)) +
           chunk(b'IEND', b''))
    return 'data:image/png;base64,' + base64.b64encode(png).decode()

def call(tag, messages):
    body = {'model': 'Qwen3.8-27B', 'messages': messages,
            'max_tokens': 8, 'stream': False}
    data = json.dumps(body).encode()
    req = urllib.request.Request(BASE, data=data, headers={
        'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    t0 = time.time()
    try:
        r = urllib.request.urlopen(req, timeout=600)
        d = json.load(r)
        el = time.time() - t0
        u = d.get('usage', {})
        print(f"[{tag}] {el:6.1f}s usage={json.dumps(u, ensure_ascii=False)}", flush=True)
    except Exception as e:
        print(f"[{tag}] ERR {time.time()-t0:.1f}s {e!r}", flush=True)

uid = uuid.uuid4().hex[:8]
fillerA = ("probe sentence alpha %s " % uid * 6 + "\n") * 500
fillerB = ("probe sentence beta %s " % uid * 6 + "\n") * 500
img = png_dataurl()

msgs_text = [{'role': 'system', 'content': 'You are a probe.'},
             {'role': 'user', 'content': fillerA + 'Reply OK.'}]
msgs_img = [{'role': 'system', 'content': 'You are a probe.'},
            {'role': 'user', 'content': [
                {'type': 'text', 'text': fillerB + 'What color? one word.'},
                {'type': 'image_url', 'image_url': {'url': img}}]}]

call('T1-text-cold', msgs_text)
call('T2-text-warm', msgs_text)
call('I1-img-cold', msgs_img)
call('I2-img-warm', msgs_img)
ext = msgs_img + [{'role': 'assistant', 'content': 'red'},
                  {'role': 'user', 'content': 'again? one word'}]
call('I3-img-append', ext)
call('T3-text-again', msgs_text)
print('DONE')
