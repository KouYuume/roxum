"""Independent grpcio and raw HTTP/2 assertions, including bounded fuzz corpora."""
import base64
import json
import pathlib
import random
import select
import socket
import struct
import subprocess
import sys
import tempfile
import urllib.parse

import grpc
from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, TrailersReceived, StreamEnded, StreamReset, ConnectionTerminated

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import stop


def verify(executable, unix):
    with tempfile.TemporaryDirectory(prefix='roxum-grpc-wire-', dir='/tmp') as directory:
        path = str(pathlib.Path(directory) / 'rpc.sock') if unix else ''
        config = pathlib.Path(directory) / 'config'
        config.mkdir()
        (config / 'local.toml').write_text('path = ' + json.dumps(path) + '\n')
        with tempfile.TemporaryFile(mode='w+') as errors:
            process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            try:
                assert select.select([process.stdout], [], [], 30)[0], 'startup timed out'
                endpoint = process.stdout.readline().strip()
                target = endpoint if unix else f'127.0.0.1:{int(endpoint)}'
                with grpc.insecure_channel(target, options=(('grpc.enable_retries', 0),)) as channel:
                    grpc.channel_ready_future(channel).result(timeout=10)
                    call = channel.unary_unary('/wire.Test/Echo')
                    for length in (0, 1, 63, 64):
                        body = bytes(range(length))
                        response, completed = call.with_call(body, timeout=5, metadata=(('token', 'first'), ('token', 'second'), ('data-bin', bytes(range(256)))))
                        assert response == body
                        assert completed.code() == grpc.StatusCode.OK
                        assert ('wire-test', 'initial') in completed.initial_metadata()
                        trailing = list(completed.trailing_metadata())
                        assert [v for k,v in trailing if k == 'token'] == ['first','second']
                        assert ('data-bin', bytes(range(256))) in trailing
                    try:
                        call(b'x'*65, timeout=5)
                    except grpc.RpcError as error:
                        assert error.code() == grpc.StatusCode.RESOURCE_EXHAUSTED
                    else:
                        raise AssertionError('message limit not enforced')
                    try:
                        channel.unary_unary('/wire.Test/Failure')(b'', timeout=5)
                    except grpc.RpcError as error:
                        assert error.code() == grpc.StatusCode.INVALID_ARGUMENT
                        assert error.details() == ' é %\n ', error.details()
                    else:
                        raise AssertionError('application error was successful')
                    assert call(b'peer', timeout=5) == b'peer'

                sock = socket.socket(socket.AF_UNIX if unix else socket.AF_INET)
                sock.settimeout(10)
                with sock:
                    sock.connect(path if unix else ('127.0.0.1', int(endpoint)))
                    client = H2Connection(config=H2Configuration(client_side=True, header_encoding='utf-8'))
                    client.initiate_connection()
                    sock.sendall(client.data_to_send())
                    stream = 1

                    def exchange(body, extra=(), content_type='application/grpc+proto', fragments=None, route='Echo', omit_te=False):
                        nonlocal stream
                        current = stream
                        stream += 2
                        headers = [(':method','POST'),(':scheme','http'),(':authority','localhost'),(':path','/wire.Test/'+route)]
                        if content_type is not None: headers.append(('content-type',content_type))
                        if not omit_te: headers.append(('te','trailers'))
                        headers.extend(extra)
                        client.send_headers(current, headers, end_stream=False)
                        pieces = [body] if fragments is None else fragments
                        for i,piece in enumerate(pieces):
                            client.send_data(current, piece, end_stream=i == len(pieces)-1)
                        sock.sendall(client.data_to_send())
                        received, trailers, output = [], [], b''
                        done = False
                        while not done:
                            packet = sock.recv(65536)
                            assert packet, 'unexpected EOF'
                            for event in client.receive_data(packet):
                                assert not isinstance(event, (StreamReset, ConnectionTerminated)), event
                                if isinstance(event, DataReceived):
                                    assert event.stream_id == current
                                    output += event.data
                                    client.acknowledge_received_data(event.flow_controlled_length, current)
                                elif isinstance(event, ResponseReceived): received = event.headers
                                elif isinstance(event, TrailersReceived): trailers = event.headers
                                elif isinstance(event, StreamEnded):
                                    assert event.stream_id == current
                                    done = True
                            pending = client.data_to_send()
                            if pending: sock.sendall(pending)
                        return dict(received), trailers, output

                    def check(body, status='0', **kwargs):
                        headers, trailing, output = exchange(body, **kwargs)
                        assert headers[':status'] == '200', (headers,body)
                        combined = {**headers, **dict(trailing)}
                        assert combined['grpc-status'] == status, (body, combined, output)
                        if status == '0': assert output == body, (body,output)
                        else: assert output == b'', output
                        return headers, trailing, output

                    frame = b'\0' + struct.pack('>I',3) + b'abc'
                    # DATA splits at every prefix/payload boundary have no effect.
                    for split in range(len(frame)+1):
                        check(frame, fragments=[frame[:split],frame[split:]])
                    for length in (0,1,2,3,4): check(b'\0'*length, '3')
                    for flag, status in ((0,'0'),(1,'12'),(2,'3'),(255,'3')):
                        check(bytes([flag])+b'\0'*4,status)
                    check(b'\0\xff\xff\xff\xff','8')
                    check(frame[:-1],'3')
                    check(frame+b'\0'*5,'3')
                    check(frame+b'x','3')
                    for media in ('application/grpc', 'Application/Grpc+Proto; charset=utf-8'):
                        check(frame,content_type=media)
                    for media in (None, 'application/json', 'application/grpc-web', 'application/grpc+json'):
                        headers, _, _ = exchange(frame,content_type=media)
                        assert headers[':status'] == '415', headers
                    check(frame,'3',omit_te=True)
                    for name in ('grpc-encoding','content-encoding'):
                        check(frame,'12',extra=[(name,'gzip')])
                        check(frame,extra=[(name,'identity')])
                        check(frame,'3',extra=[(name,'identity'),(name,'identity')])
                    check(frame,'3',extra=[('content-type','application/grpc')])
                    check(frame,'3',extra=[('grpc-encoding','')])
                    # Binary metadata accepts joined and padded/unpadded forms,
                    # preserves duplicate order, and emits canonical unpadded data.
                    _, trailing, _ = check(frame,extra=[('x-bin','Zg==, Zm8'),('x-bin','')])
                    assert [v for k,v in trailing if k=='x-bin'] == ['Zg','Zm8',''], trailing
                    for bad in ('a','!!!!','====','Zg=','Zh==','Zg==Zg=='):
                        check(frame,'3',extra=[('x-bin',bad)])
                    _, trailing, _ = check(frame,extra=[('x-ascii',b'\xff')])
                    assert not any(k == 'x-ascii' for k,_ in trailing)
                    for count in (61,62,63):
                        check(frame,'8' if count>62 else '0',extra=[('x-bin',','.join(['']*count))])
                    headers, trailing, output = exchange(b'\0'*5,route='Failure')
                    assert output == b'' and dict(trailing)['grpc-status']=='3'
                    assert urllib.parse.unquote(dict(trailing)['grpc-message']) == ' é %\n '
                    # Independent finite-envelope oracle over arbitrary and
                    # structured bytes. Fixed seed retains the failure corpus.
                    rng = random.Random(9143)
                    for index in range(256):
                        payload = bytes(rng.randrange(256) for _ in range(rng.randrange(90)))
                        declared = rng.choice([len(payload),0,63,64,65,0xffffffff])
                        flag = rng.choice([0,0,1,2,255])
                        data = bytes([flag])+struct.pack('>I',declared)+payload
                        expected = '3' if flag>1 else '12' if flag==1 else '8' if declared>64 else '3' if declared!=len(payload) else '0'
                        check(data,expected)
                    for length in range(65):
                        raw = bytes(rng.randrange(256) for _ in range(length))
                        encoded = base64.b64encode(raw).decode()
                        _, trailing, _ = check(frame,extra=[('fuzz-bin',encoded if length%2 else encoded.rstrip('='))])
                        assert [v for k,v in trailing if k=='fuzz-bin'] == [encoded.rstrip('=')]
                    for _ in range(128):
                        text = ''.join(rng.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/= !?') for _ in range(rng.randrange(24)))
                        stripped = text.strip(' ')
                        unpadded = stripped.rstrip('=')
                        padding = len(stripped)-len(unpadded)
                        valid = padding <= 2 and len(unpadded)%4 != 1 and (padding == 0 or len(stripped)%4 == 0)
                        try:
                            decoded = base64.b64decode(unpadded+'='*((-len(unpadded))%4), validate=True)
                            valid = valid and base64.b64encode(decoded).decode().rstrip('=') == unpadded
                        except ValueError:
                            valid = False
                        _, trailing, _ = check(frame, '0' if valid else '3', extra=[('random-bin',text)])
                        if valid:
                            assert [v for k,v in trailing if k=='random-bin'] == [unpadded]
                    check(frame)  # An invalid call never kills the connection.
                assert stop(process) == 0
            except BaseException:
                stop(process)
                errors.seek(0)
                print(errors.read(), file=sys.stderr)
                raise
            finally:
                process.stdout.close()
    print('PASS gRPC wire and metadata ' + ('Unix' if unix else 'TCP'))


if __name__ == '__main__':
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    verify(executable, False)
    verify(executable, True)
