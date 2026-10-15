"""Run with: python3 -m unittest discover -s tests -v."""
import base64
import fcntl
import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import termios
import unittest

ROOT = Path(__file__).resolve().parents[1]
EDITORS = [shutil.which(name) for name in ('vim', 'nvim') if shutil.which(name)]


class CopyPathTest(unittest.TestCase):
    def copy_path(self, editor, tools=(), tmux=False, terminal=False, fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bindir = tmp / 'bin'
            bindir.mkdir()
            for tool in tools:
                script = bindir / tool
                script.write_text('#!/bin/sh\n' + ('exit 1\n' if fail else
                                  '/bin/cat > "$CAPTURE"\n'))
                script.chmod(0o755)
            if terminal:
                (bindir / 'base64').symlink_to(shutil.which('base64'))
            directory = tmp / 'files'
            directory.mkdir()
            name = "a 'quote' café.txt"
            (directory / name).touch()
            expected = str(directory / name)
            script = tmp / 'test.vim'
            script.write_text("set nocompatible\nset rtp^=" + str(ROOT) + "\n"
                              "set encoding=utf-8 shell=/bin/sh\n"
                              "runtime plugin/vimexplorer.vim\n"
                              "let g:vimexplorer_detail = 0\n"
                              "let g:vimexplorer_show_header = 0\n"
                              "call vimexplorer#Open($TEST_DIR)\n"
                              "call cursor(1, 1)\n"
                              "redir => message\n"
                              "silent call vimexplorer#CopyPath()\n"
                              "redir END\n"
                              "call writefile([getreg('\"'), message], $RESULT)\n"
                              "qa!\n")
            env = dict(os.environ, PATH=str(bindir), TEST_DIR=str(directory),
                       CAPTURE=str(tmp / 'clipboard'), RESULT=str(tmp / 'result'),
                       DISPLAY=':test' if 'xclip' in tools or 'xsel' in tools else '',
                       WAYLAND_DISPLAY='test' if 'wl-copy' in tools else '',
                       TMUX='test' if tmux else '', TERM='xterm-256color')
            master, slave = pty.openpty()

            def setup_terminal():
                os.setsid()
                if terminal:
                    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

            args = [editor, '-u', 'NONE', '-i', 'NONE', '-n', '-es',
                    '-V1' + str(tmp / 'log'), '-S', str(script)]
            process = subprocess.Popen(args, env=env, stdin=slave, stdout=slave,
                                       stderr=slave, preexec_fn=setup_terminal)
            process.wait(timeout=10)
            os.close(slave)
            output = b''
            try:
                while True:
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    output += chunk
            except OSError:
                pass
            finally:
                os.close(master)
            self.assertEqual(process.returncode, 0, (tmp / 'log').read_text())
            result = (tmp / 'result').read_text()
            self.assertEqual(result.splitlines()[0], expected)
            clipboard = tmp / 'clipboard'
            return expected, clipboard.read_bytes() if clipboard.exists() else None, output, result

    def test_desktop_clipboard(self):
        for editor in EDITORS:
            for tool in ('wl-copy', 'xclip', 'xsel', 'pbcopy'):
                with self.subTest(editor=editor, tool=tool):
                    expected, copied, _, result = self.copy_path(editor, (tool,), tmux=True)
                    self.assertEqual(copied, expected.encode())
                    self.assertIn('Copied:', result)

    def test_osc52_with_and_without_tmux(self):
        for editor in EDITORS:
            for tmux in (False, True):
                with self.subTest(editor=editor, tmux=tmux):
                    expected, _, output, result = self.copy_path(editor, tmux=tmux, terminal=True)
                    sequence = b'\x1b]52;c;' + base64.b64encode(expected.encode()) + b'\x07'
                    if tmux:
                        sequence = b'\x1bPtmux;\x1b' + sequence + b'\x1b\\'
                    self.assertIn(sequence, output)
                    self.assertIn('OSC 52', result)

    def test_failed_tool_falls_back_to_osc52(self):
        for editor in EDITORS:
            with self.subTest(editor=editor):
                expected, _, output, _ = self.copy_path(editor, ('wl-copy',), terminal=True, fail=True)
                self.assertIn(base64.b64encode(expected.encode()), output)

    def test_no_clipboard_reports_failure_but_keeps_vim_register(self):
        for editor in EDITORS:
            with self.subTest(editor=editor):
                _, _, _, result = self.copy_path(editor)
                self.assertIn('clipboard unavailable', result)
                self.assertNotIn('Copied:', result)


if __name__ == '__main__':
    unittest.main()
