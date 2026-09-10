#!/usr/bin/env python3
"""Create and read back a private encrypted snapshot, then reopen A without switching.

Run from the supplied .command in Terminal so closing Codex does not stop the helper.
This proves file/SQLite readback only, not restored-browser decryption or final acceptance.
"""
import argparse
import datetime as dt
import getpass
import hashlib
import json
import math
import os
import pathlib
import plistlib
import re
import secrets
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time


def run(args, password=None):
    return subprocess.run(args, input=(password+'\n').encode() if password else None,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def is_writer(path):
    # Match the native Host classifier; no blanket exemption by executable name.
    crash_reporter=r'/Applications/Codex\.app/Contents/Frameworks/Codex Framework\.framework/Versions/[0-9]+(?:\.[0-9]+){3}/Helpers/browser_crashpad_handler'
    if re.fullmatch(crash_reporter,path): return False
    return pathlib.Path(path).name.lower() in ['codex','codex-app-server','codex-daemon'] or '/Codex.app/' in path or '/Codex/codex-browser-app/' in path


def writers():
    rows=run(['/bin/ps','-axo','comm=']).decode().splitlines()
    return [p for p in rows if is_writer(p)]


class RunStatus:
    """Allowlisted progress only. Never accepts passwords, process arguments or file bodies."""
    phases={'password','waiting_for_exit','backup','verified','complete','cancelled','failed'}
    def __init__(self,root=None):
        self.root=root or pathlib.Path.home()/'Library/Application Support/CodexAccountSwitcher/acceptance'
        self.root.mkdir(mode=0o700,parents=True,exist_ok=True)
        info=self.root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077: raise ValueError('unsafe status directory')
        self.run_id=f'{os.getpid()}-{time.time_ns()}'
    def set(self,phase,blocking_count=None):
        if phase not in self.phases or blocking_count is not None and (type(blocking_count) is not int or blocking_count<0): raise ValueError('invalid status')
        value={'schema':1,'run_id':self.run_id,'pid':os.getpid(),'phase':phase,'updated_at':dt.datetime.now(dt.timezone.utc).isoformat()}
        if blocking_count is not None: value['blocking_count']=blocking_count
        fd,raw=tempfile.mkstemp(prefix='.backup-status-',dir=self.root)
        try:
            with os.fdopen(fd,'w') as f: json.dump(value,f);f.flush();os.fsync(f.fileno())
            os.replace(raw,self.root/'latest-backup-status.json')
        finally:
            if os.path.exists(raw):os.unlink(raw)


def wait_for_exit(status,timeout=900,scanner=None,clock=None,sleep=None,output=None):
    scanner=scanner or writers;clock=clock or time.monotonic;sleep=sleep or time.sleep
    output=output or (lambda text:print(text,flush=True))
    deadline=clock()+timeout;last_count=None;last_notice=-float('inf')
    while True:
        count=len(scanner())
        status.set('waiting_for_exit',blocking_count=count)
        if count==0:
            sleep(3)
            if not scanner(): return
            continue
        if clock()>deadline: raise TimeoutError('writers did not stop')
        if count!=last_count or clock()-last_notice>=30:
            output(f'等待 {count} 个 Codex/CLI/浏览器业务进程退出。请保留此终端，完成后会自动重开 Codex。')
            last_count=count;last_notice=clock()
        sleep(2)


def inventory(root):
    rows={}
    paths=[root]+sorted(root.rglob('*')) if root.is_dir() and not root.is_symlink() else [root]
    for p in paths:
        rel=str(p.relative_to(root))
        info=p.lstat()
        if stat.S_ISLNK(info.st_mode): rows[rel]={'link':os.readlink(p)}
        elif stat.S_ISREG(info.st_mode):
            # Terminal may use a different Python than the development shell.
            # Stream explicitly so macOS Python versions before 3.11 also work.
            with p.open('rb') as f:
                hasher=hashlib.sha256()
                for chunk in iter(lambda:f.read(1024*1024),b''): hasher.update(chunk)
                digest=hasher.hexdigest()
            rows[rel]={'sha256':digest,'size':info.st_size}
        elif stat.S_ISDIR(info.st_mode): rows[rel]={'directory':True}
        else: raise ValueError('unsupported file type')
    return rows


def sqlite_readback(root):
    checked=0
    for p in root.rglob('*'):
        if not p.is_file() or p.is_symlink() or p.name.endswith(('-wal','-shm')): continue
        with p.open('rb') as f: header=f.read(16)
        if header!=b'SQLite format 3\x00': continue
        conn=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True,timeout=5)
        try:
            if conn.execute('PRAGMA quick_check').fetchall()!=[('ok',)]: raise ValueError('sqlite integrity')
        finally: conn.close()
        checked+=1
    return checked


def snapshot(sources, destination, password, stopped):
    if stopped and writers(): raise ValueError('Codex still running')
    before={name:inventory(path) for name,path in sources.items()}
    size=sum(v.get('size',0) for rows in before.values() for v in rows.values())
    if shutil.disk_usage(destination).free < size*2+2*1024**3: raise ValueError('free space')
    image=destination/'codex-before-control.sparsebundle'
    mount=destination/'mounted'
    if image.exists() or mount.exists(): raise ValueError('output already exists')
    mount.mkdir(mode=0o700)
    gib=max(1,math.ceil(size/1024**3*1.4)+2)
    run(['/usr/bin/hdiutil','create','-size',f'{gib}g','-type','SPARSEBUNDLE','-fs','APFS',
         '-volname','Codex acceptance backup','-nospotlight','-encryption','AES-256','-stdinpass',str(image)],password)
    if plistlib.loads(run(['/usr/bin/hdiutil','isencrypted',str(image),'-plist'])).get('encrypted') is not True:
        raise ValueError('image encryption not verified')
    attached=False
    try:
        run(['/usr/bin/hdiutil','attach','-nobrowse','-mountpoint',str(mount),'-stdinpass',str(image)],password);attached=True
        payload=mount/'payload';payload.mkdir(mode=0o700)
        for n,(name,path) in enumerate(sources.items(),1):
            print(f'备份对象 {n}/{len(sources)}',flush=True)
            run(['/usr/bin/ditto',str(path),str(payload/name)])
        if stopped and writers(): raise ValueError('Codex reopened during backup')
        after={name:inventory(path) for name,path in sources.items()}
        copied={name:inventory(payload/name) for name in sources}
        if before!=after or before!=copied: raise ValueError('source changed or copy mismatch')
        manifest={'schema':1,'files':copied,'bytes':size,'captured_at':dt.datetime.now(dt.timezone.utc).isoformat()}
        (mount/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,sort_keys=True))
        os.chmod(mount/'manifest.json',0o600)
        run(['/usr/bin/hdiutil','detach',str(mount)]);attached=False
        # Remount the actual encrypted artifact, rather than trusting the first mounted copy.
        run(['/usr/bin/hdiutil','attach','-nobrowse','-mountpoint',str(mount),'-stdinpass',str(image)],password);attached=True
        restored=json.loads((mount/'manifest.json').read_text())
        if {name:inventory(mount/'payload'/name) for name in sources}!=restored['files']: raise ValueError('remount mismatch')
        checked=sqlite_readback(mount/'payload')
        receipt={'encrypted_image_created':True,'remounted_file_readback':'PASS','sqlite_quick_check_count':checked,
                 'bytes':size,'restored_browser_function':'NOT_RUN','restored_history_function':'NOT_RUN',
                 'account_switch_performed':False,'original_data_written':False}
    finally:
        if attached: run(['/usr/bin/hdiutil','detach',str(mount)])
    fd=os.open(destination/'receipt.json',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as f: json.dump(receipt,f,indent=2)
    print(json.dumps(receipt),flush=True)
    return receipt


def live_sources():
    home=pathlib.Path.home(); codex=home/'.codex'
    sources={}
    for name in ['sessions','archived_sessions','memories','automations']:
        p=codex/name
        if p.exists(): sources['codex-'+name]=p
    for p in sorted(codex.iterdir()):
        if p.is_file() and not p.is_symlink(): sources['codex-file-'+p.name]=p
    for name in ['Codex','com.openai.codex','CodexAccountSwitcher']:
        p=home/'Library/Application Support'/name
        # The switcher vault itself is Keychain; accounts.json is its recoverable index.
        if name=='CodexAccountSwitcher': p=p/'accounts.json'
        if p.exists(): sources['support-'+name]=p
    return sources


def request_password(reader=None, writer=None):
    reader=reader or getpass.getpass
    writer=writer or (lambda message: print(message,flush=True))
    writer('请设置至少 12 个字符的本地备份密码，并自行保存。输入时不显示文字或星号，这是正常的。')
    writer('输错可以重新输入；按 Control+C 可取消，不会开始备份或切换账号。')
    while True:
        password=reader('设置备份密码（至少 12 个字符）：')
        if len(password)<12:
            writer('密码不足 12 个字符，请重新设置。')
            continue
        if any(c in password for c in ['\x00','\r','\n']):
            writer('密码不能包含换行或空字符，请重新设置。')
            continue
        confirmation=reader('再次输入相同密码：')
        if password!=confirmation:
            writer('两次输入不一致，请重新设置并确认。')
            continue
        writer('密码已确认。')
        return password


def main(argv=None):
    parser=argparse.ArgumentParser()
    parser.add_argument('--synthetic-smoke',action='store_true')
    args=parser.parse_args(argv)
    os.umask(0o077)
    stage='检查启动环境'
    destination=None
    status=None
    try:
        if args.synthetic_smoke:
            with tempfile.TemporaryDirectory(prefix='switcher-encrypted-backup-test-') as tmp:
                root=pathlib.Path(tmp);source=root/'source';source.mkdir();out=root/'out';out.mkdir()
                (source/'marker.txt').write_text('synthetic continuity marker')
                with sqlite3.connect(source/'test.sqlite') as db:
                    db.execute('CREATE TABLE sample (marker TEXT)');db.execute('INSERT INTO sample VALUES (?)',('synthetic',))
                result=snapshot({'synthetic':source},out,secrets.token_hex(32),False)
                assert result['sqlite_quick_check_count']==1
                print('PASS: encrypted image, detach/remount, exact file readback, SQLite integrity; synthetic data only')
        else:
            if not sys.stdin.isatty():
                print('请在系统 Terminal 中打开“开始备份与重启对照.command”。本轮未开始备份。',flush=True)
                return 1
            print('本工具只备份并重开原账号 A，不切换账号。先保存其他 Codex/CLI/IDE 工作。')
            print('备份包含本机 Codex 任务、桌面浏览器、已生成记忆和账号索引；不复制原始 History 事件。')
            status=RunStatus();status.set('password')
            stage='设置备份密码'
            password=request_password()
            stage='等待 Codex 退出'
            print('现在请正常退出 Codex，并退出共享认证的 CLI/IDE 后端。不要关闭此终端。',flush=True)
            wait_for_exit(status)
            stage='创建并核验加密备份'
            status.set('backup')
            destination=pathlib.Path.home()/'Library/Application Support/CodexAccountSwitcherBackups'/dt.datetime.now().strftime('%Y%m%d-%H%M%S')
            destination.mkdir(mode=0o700,parents=True)
            snapshot(live_sources(),destination,password,True)
            status.set('verified')
            password=None
            stage='重开原账号 A'
            print('加密备份及文件回读已通过。现在重开原账号 A；回到验收任务回复“已重开”。',flush=True)
            run(['/usr/bin/open','-a','/Applications/Codex.app'])
            status.set('complete')
        return 0
    except (KeyboardInterrupt,EOFError):
        if status is not None: status.set('cancelled')
        print('\n已取消，未切换账号。'+('本轮未开始备份。' if destination is None else '本轮加密材料保留，尚未通过备份核验。'),flush=True)
        return 130
    except Exception as error:
        if status is not None: status.set('failed')
        if args.synthetic_smoke:
            import traceback
            traceback.print_exc()
        if stage=='重开原账号 A':
            print('备份回读已通过，但未能自动打开 Codex；请手动打开原账号 A。未切换账号。',flush=True)
        else:
            print('未完成：'+stage+'（'+type(error).__name__+'）。未切换账号。'+
                  ('本轮未开始备份。' if destination is None else '本轮加密材料保留，尚未通过备份核验。'),flush=True)
        return 1


if __name__=='__main__':
    raise SystemExit(main())
