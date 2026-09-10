#!/usr/bin/env python3
"""Regression tests use synthetic passwords only; never run the live snapshot."""
import contextlib
import io
import json
import os
import pathlib
import pty
import select
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import backup_before_control as backup


class Terminal:
    def __init__(self,args,env=None):
        self.master,slave=pty.openpty()
        self.process=subprocess.Popen(args,stdin=slave,stdout=slave,stderr=slave,env=env)
        os.close(slave)
        self.buffer=b'';self.transcript=b''
    def expect(self,text):
        target=text.encode();deadline=time.monotonic()+8
        while target not in self.buffer:
            if time.monotonic()>deadline: raise AssertionError('expected terminal output did not arrive')
            if not select.select([self.master],[],[],.1)[0]: continue
            try: chunk=os.read(self.master,8192)
            except OSError: chunk=b''
            if not chunk: raise AssertionError('terminal exited before expected prompt')
            self.buffer+=chunk;self.transcript+=chunk
        self.buffer=self.buffer.split(target,1)[1]
    def send(self,value): os.write(self.master,value.encode())
    def close(self):
        if self.process.poll() is None:
            self.process.terminate();self.process.wait(timeout=5)
        os.close(self.master)


class PasswordTests(unittest.TestCase):
    def request(self,values):
        messages=[];items=iter(values)
        result=backup.request_password(lambda prompt:next(items),messages.append)
        return result,'\n'.join(messages)

    def test_empty_and_short_inputs_retry(self):
        value='SYNTHETIC-valid-123'
        result,out=self.request(['','short',value,value])
        self.assertEqual(result,value)
        self.assertEqual(out.count('密码不足'),2)
        self.assertNotIn(value,out)

    def test_mismatch_retries_without_echoing_input(self):
        first='SYNTHETIC-first-123';second='SYNTHETIC-second-456'
        result,out=self.request([first,second,second,second])
        self.assertEqual(result,second);self.assertIn('两次输入不一致',out)
        self.assertNotIn(first,out);self.assertNotIn(second,out)

    def test_exact_minimum_is_accepted(self):
        value='123456789012'
        result,out=self.request([value,value])
        self.assertEqual(result,value);self.assertIn('密码已确认',out)

    def test_stdin_delimiters_are_rejected(self):
        value='SYNTHETIC-valid-123'
        result,out=self.request([value+'\x00',value+'\n',value+'\r',value,value])
        self.assertEqual(result,value);self.assertEqual(out.count('不能包含'),3)

    def test_cancel_before_confirmation_never_starts_backup(self):
        output=io.StringIO()
        with patch.object(backup.sys.stdin,'isatty',return_value=True), \
             patch.object(backup.getpass,'getpass',side_effect=KeyboardInterrupt), \
             patch.object(backup,'RunStatus'), \
             patch.object(backup,'snapshot') as snapshot, \
             patch.object(backup,'writers') as writers,contextlib.redirect_stdout(output):
            self.assertEqual(backup.main([]),130)
            snapshot.assert_not_called();writers.assert_not_called()
        self.assertIn('本轮未开始备份',output.getvalue())

    def test_real_pty_getpass_retry_and_no_echo(self):
        root=pathlib.Path(__file__).resolve().parent
        code='import sys;sys.path.insert(0,sys.argv[1]);from backup_before_control import request_password;request_password();print("PASSWORD_TEST_DONE",flush=True)'
        term=Terminal([sys.executable,'-c',code,str(root)])
        value='SYNTHETIC-pty-9876';wrong='SYNTHETIC-other-5432'
        try:
            term.expect('设置备份密码（至少 12 个字符）：');term.send('short\n')
            term.expect('密码不足 12 个字符');term.expect('设置备份密码（至少 12 个字符）：')
            term.send(value+'\n');term.expect('再次输入相同密码：');term.send(wrong+'\n')
            term.expect('两次输入不一致');term.expect('设置备份密码（至少 12 个字符）：')
            term.send(value+'\n');term.expect('再次输入相同密码：');term.send(value+'\n')
            term.expect('PASSWORD_TEST_DONE');self.assertEqual(term.process.wait(timeout=5),0)
            for secret in ['short',value,wrong]: self.assertNotIn(secret.encode(),term.transcript)
        finally: term.close()

    def test_command_wrapper_retains_failure_until_enter(self):
        wrapper=pathlib.Path(__file__).resolve().parent.parent/'开始备份与重启对照.command'
        with tempfile.TemporaryDirectory(prefix='switcher-prompt-test-') as tmp:
            fake=pathlib.Path(tmp)/'python3';fake.write_text('#!/bin/sh\necho SYNTHETIC_FAILURE\nexit 7\n');fake.chmod(0o700)
            env=dict(os.environ);env['PATH']=tmp+os.pathsep+env.get('PATH','')
            term=Terminal(['/bin/zsh',str(wrapper)],env)
            try:
                term.expect('SYNTHETIC_FAILURE');term.expect('结果已保留在上方。按回车结束此窗口。')
                self.assertIsNone(term.process.poll());term.send('\n')
                self.assertEqual(term.process.wait(timeout=5),7)
            finally: term.close()


class ExitGateTests(unittest.TestCase):
    reporter='/Applications/Codex.app/Contents/Frameworks/Codex Framework.framework/Versions/152.0.7977.83/Helpers/browser_crashpad_handler'

    def test_crash_reporter_does_not_block_but_real_writers_do(self):
        self.assertFalse(backup.is_writer(self.reporter))
        for path in ['/Applications/Codex.app/Contents/MacOS/ChatGPT','/Applications/Codex.app/Contents/Resources/codex',
                     '/opt/bin/codex','/opt/bin/codex-daemon','/tmp/Codex.app/Contents/Helpers/browser_crashpad_handler',
                     self.reporter+'-other','/Users/test/Library/Application Support/Codex/codex-browser-app/browser']:
            self.assertTrue(backup.is_writer(path),path)

    def test_diagnostic_only_processes_allow_quiet_period(self):
        scanner=lambda:[p for p in [self.reporter,self.reporter] if backup.is_writer(p)]
        sleeps=[]
        with patch.object(backup,'RunStatus') as status:
            backup.wait_for_exit(status,scanner=scanner,sleep=sleeps.append)
            status.set.assert_called_with('waiting_for_exit',blocking_count=0)
        self.assertEqual(sleeps,[3])

    def test_reappearing_writer_restarts_quiet_check(self):
        scans=iter([[],['real writer'],['real writer'],[],[]]);sleeps=[];messages=[]
        with patch.object(backup,'RunStatus') as status:
            backup.wait_for_exit(status,scanner=lambda:next(scans),sleep=sleeps.append,output=messages.append)
        self.assertEqual(sleeps,[3,2,3]);self.assertEqual(len(messages),1)

    def test_real_writer_timeout_never_passes(self):
        timer=iter([0,2,4,6,8,10])
        with patch.object(backup,'RunStatus') as status:
            with self.assertRaises(TimeoutError):
                backup.wait_for_exit(status,timeout=1,scanner=lambda:['real writer'],clock=lambda:next(timer),sleep=lambda t:None)

    def test_status_is_private_and_allowlisted(self):
        with tempfile.TemporaryDirectory(prefix='switcher-status-test-') as tmp:
            root=pathlib.Path(tmp);status=backup.RunStatus(root)
            status.set('waiting_for_exit',blocking_count=2)
            target=root/'latest-backup-status.json';value=json.loads(target.read_text())
            self.assertEqual(value['phase'],'waiting_for_exit');self.assertEqual(value['blocking_count'],2)
            self.assertEqual(target.stat().st_mode&0o777,0o600)
            self.assertEqual(set(value),{'schema','run_id','pid','phase','updated_at','blocking_count'})
            with self.assertRaises(ValueError):status.set('SYNTHETIC_SECRET')
            self.assertNotIn('SYNTHETIC_SECRET',target.read_text())
            self.assertFalse(list(root.glob('.backup-status-*')))


if __name__=='__main__': unittest.main()
