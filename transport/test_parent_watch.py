import subprocess
import sys
import unittest


class ParentWatchTests(unittest.TestCase):
    def test_exit_with_parent_pipe_open_is_clean(self):
        script = ('import threading,time\n'
                  'from route_runtime import watch_parent\n'
                  't=threading.Thread(target=watch_parent,args=(0,threading.Event()),daemon=True)\n'
                  't.start(); time.sleep(0.1)\n')
        process = subprocess.Popen([sys.executable, '-B', '-c', script], stdin=subprocess.PIPE,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            code=process.wait(timeout=5)
            self.assertEqual(code, 0, 'runtime aborted while parent pipe was still open')
        finally:
            process.stdin.close()
            process.stderr.close()
            if process.poll() is None:
                process.terminate(); process.wait(timeout=5)


if __name__ == '__main__': unittest.main()
