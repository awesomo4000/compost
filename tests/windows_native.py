#!/usr/bin/env python3
"""Native Windows ConPTY integration. Run with Python on Windows, without WSL.

Every test owns its processes and uses a disposable directory. An outer ConPTY
exercises compo console input/output; compo creates the inner shell ConPTYs.
"""
import ctypes as C
from ctypes import wintypes as W
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

if sys.platform != 'win32':
    raise SystemExit('Run this test on native Windows')
k = C.WinDLL('kernel32', use_last_error=True)
H = W.HANDLE
class Coord(C.Structure):
    _fields_ = [('X', C.c_short), ('Y', C.c_short)]
class Startup(C.Structure):
    _fields_ = [('cb', W.DWORD), ('reserved', W.LPWSTR), ('desktop', W.LPWSTR),
                ('title', W.LPWSTR), ('x', W.DWORD), ('y', W.DWORD),
                ('xs', W.DWORD), ('ys', W.DWORD), ('xc', W.DWORD),
                ('yc', W.DWORD), ('fill', W.DWORD), ('flags', W.DWORD),
                ('show', W.WORD), ('reserved2size', W.WORD),
                ('reserved2', C.c_void_p), ('stdin', H), ('stdout', H), ('stderr', H)]
class StartupEx(C.Structure):
    _fields_ = [('startup', Startup), ('attributes', C.c_void_p)]
class Process(C.Structure):
    _fields_ = [('process', H), ('thread', H), ('pid', W.DWORD), ('tid', W.DWORD)]
def api(name, args, result=W.BOOL):
    fn=getattr(k,name); fn.argtypes=args; fn.restype=result; return fn
pipe=api('CreatePipe',[C.POINTER(H),C.POINTER(H),C.c_void_p,W.DWORD])
close=api('CloseHandle',[H])
read=api('ReadFile',[H,C.c_void_p,W.DWORD,C.POINTER(W.DWORD),C.c_void_p])
write=api('WriteFile',[H,C.c_void_p,W.DWORD,C.POINTER(W.DWORD),C.c_void_p])
create_pc=api('CreatePseudoConsole',[Coord,H,H,W.DWORD,C.POINTER(H)],C.c_long)
close_pc=api('ClosePseudoConsole',[H],None)
resize_pc=api('ResizePseudoConsole',[H,Coord],C.c_long)
init_attrs=api('InitializeProcThreadAttributeList',[C.c_void_p,W.DWORD,W.DWORD,C.POINTER(C.c_size_t)])
update_attrs=api('UpdateProcThreadAttribute',[C.c_void_p,W.DWORD,C.c_size_t,C.c_void_p,C.c_size_t,C.c_void_p,C.c_void_p])
delete_attrs=api('DeleteProcThreadAttributeList',[C.c_void_p],None)
create_process=api('CreateProcessW',[W.LPCWSTR,W.LPWSTR,C.c_void_p,C.c_void_p,W.BOOL,W.DWORD,C.c_void_p,W.LPCWSTR,C.POINTER(Startup),C.POINTER(Process)])
wait=api('WaitForSingleObject',[H,W.DWORD],W.DWORD)
terminate=api('TerminateProcess',[H,W.UINT])
def check(value):
    if not value: raise C.WinError(C.get_last_error())

class Console:
    def __init__(self, argv):
        self.data=bytearray(); self.handles=[]
        ir,iw,ore,ow=H(),H(),H(),H()
        check(pipe(C.byref(ir),C.byref(iw),None,0)); check(pipe(C.byref(ore),C.byref(ow),None,0))
        self.pc=H(); assert create_pc(Coord(100,30),ir,ow,0,C.byref(self.pc))==0
        close(ir); close(ow); self.input=iw; self.output=ore
        def drain():
            buf=C.create_string_buffer(65536); n=W.DWORD()
            while read(ore,buf,len(buf),C.byref(n),None) and n.value:
                self.data.extend(buf.raw[:n.value])
        self.reader=threading.Thread(target=drain,daemon=True); self.reader.start()
        size=C.c_size_t(); init_attrs(None,1,0,C.byref(size)); attrs=C.create_string_buffer(size.value)
        check(init_attrs(attrs,1,0,C.byref(size)))
        check(update_attrs(attrs,0,0x20016,self.pc,C.sizeof(H),None,None))
        si=StartupEx(); si.startup.cb=C.sizeof(si); si.startup.flags=0x100; si.attributes=C.addressof(attrs)
        self.pi=Process(); line=C.create_unicode_buffer(subprocess.list2cmdline(argv))
        check(create_process(argv[0],line,None,None,False,0x80000,None,None,C.byref(si.startup),C.byref(self.pi)))
        delete_attrs(attrs); close(self.pi.thread)
    def send(self,data):
        n=W.DWORD(); check(write(self.input,data,len(data),C.byref(n),None)); assert n.value==len(data)
    def until(self,predicate,label,seconds=15):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            if predicate():return
            assert wait(self.pi.process,0)==258, 'compo exited while waiting for '+label
            time.sleep(.02)
        raise AssertionError('timeout: '+label+'; output tail: '+repr(bytes(self.data[-1500:])))
    def stop(self):
        if wait(self.pi.process,0)==258:
            self.send(b'\x1dq')
            if wait(self.pi.process,5000)==258: terminate(self.pi.process,1)
        close_pc(self.pc); close(self.input); self.reader.join(5); close(self.output); close(self.pi.process)

binary=str(Path(sys.argv[1] if len(sys.argv)>1 else Path(__file__).resolve().parents[1]/'zig-out/bin/compo.exe').resolve())
with tempfile.TemporaryDirectory(prefix='compo-native-test-') as directory:
    console=Console([binary,'--no-init','--no-title'])
    try:
        console.until(lambda:b'COMPO_SOCKET=' in console.data and b'\n' in console.data.split(b'COMPO_SOCKET=',1)[1], 'socket announcement')
        clean=re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', bytes(console.data))
        clean=re.sub(rb'\x1b\][^\x07]*\x07', b'', clean)
        socket=re.search(rb'COMPO_SOCKET=(.+?control\.sock)', clean).group(1).decode()
        def ctl(*args):
            result=subprocess.run([binary,'ctl','--socket',socket,*args],capture_output=True,timeout=15)
            assert result.returncode==0,(args,result.stdout,result.stderr)
            return json.loads(result.stdout)['result']
        for name,shell,command,typed in [
            ('powershell',r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',"[IO.File]::WriteAllText('%s','ready')", "[IO.File]::WriteAllText('%s','typed')"),
            ('cmd',r'C:\Windows\System32\cmd.exe','echo ready > "%s"','echo typed > "%s"'),
            ('bash',r'C:\Program Files\Git\bin\bash.exe',"printf ready > '%s'", "printf typed > '%s'")]:
            marker=Path(directory)/(name+' ready'); second=Path(directory)/(name+' typed')
            ctl('create','--tile','--name',name,'--focus','--shell',shell,'--command',command % str(marker).replace('\\','/'))
            console.until(marker.exists,name+' initial command')
            # Each --command must leave an interactive shell accepting more input.
            time.sleep(.5)
            console.send((typed % str(second).replace('\\','/')+'\r').encode())
            console.until(lambda:second.exists() and 'typed' in second.read_text(),name+' keyboard input')
            assert b'\xe2\x94' in console.data, 'UTF-8 box borders were not preserved'
            console.send(b'echo COMPO_RENDER_OK\r')
            console.until(lambda:b'COMPO_RENDER_OK' in console.data,name+' redraw')
            assert resize_pc(console.pc,Coord(110,35))==0
            console.until(lambda:ctl('get',name)['window']['columns']==108,name+' resize')
            console.send(b'exit\r')
            console.until(lambda:ctl('list')['windows']==[],name+' shell exit')
            assert resize_pc(console.pc,Coord(100,30))==0
            time.sleep(.1)
            print('PASS',name,'command, interactive input, redraw, resize, shell exit',flush=True)
        ctl('create','--tile','--name','left','--focus')
        ctl('create','--tile','--name','right','--edge','right')
        right=ctl('get','right')['window']['content']
        x,y=right['x']+2,right['y']+2
        console.send(f'\x1b[<0;{x};{y}M\x1b[<0;{x};{y}m'.encode())
        console.until(lambda:ctl('get','right')['window']['focused'],'mouse focus')
        console.send(b'\x1d1')
        console.until(lambda:ctl('get','left')['window']['focused'],'number focus')
        ctl('close','left'); ctl('close','right')
        assert ctl('default-shell',r'C:\Program Files\Git\bin\bash.exe')['shell'].endswith('bash.exe')
        assert ctl('default-shell')['shell'].endswith('bash.exe')
        console.send(b'\x1d\r')
        console.until(lambda:len(ctl('list')['windows'])==1,'prefix new shell')
        marker=Path(directory)/'default-shell-marker'
        console.send(("printf bash > '%s'\r" % str(marker).replace('\\','/')).encode())
        console.until(marker.exists,'configured default shell from prefix')
        print('PASS mouse focus, numbered focus, configured prefix shell',flush=True)
        console.send(b'\x1dq')
        assert wait(console.pi.process,5000)==0,'quit did not exit'
        print('PASS native console quit',flush=True)
    finally:console.stop()

    for extension,body in [
        ('.ps1', '& $env:COMPO_BIN ctl --quiet create --tile --name scripted\n'),
        ('.sh', '"$COMPO_BIN" ctl --quiet create --tile --name scripted\n')]:
        script=Path(directory)/('layout'+extension); script.write_text(body)
        console=Console([binary,'--init',str(script),'--no-title'])
        try:
            console.until(lambda:b'control.sock' in console.data,'startup socket')
            clean=re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07',b'',bytes(console.data))
            socket=re.search(rb'COMPO_SOCKET=(.+?control\.sock)',clean).group(1).decode()
            console.until(lambda:len(ctl('list')['windows'])==1,extension+' startup')
            old=ctl('get','scripted')['window']['window']
            ctl('reload')
            console.until(lambda:len(ctl('list')['windows'])==1 and ctl('get','scripted')['window']['window']!=old,extension+' reload')
            print('PASS',extension,'startup and reload',flush=True)
        finally:console.stop()
