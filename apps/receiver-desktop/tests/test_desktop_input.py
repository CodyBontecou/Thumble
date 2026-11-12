import unittest
from thumble_receiver.desktop_input import DesktopOutput, KEYS
from thumble_receiver.state import State, NEUTRAL
from thumble_receiver.output import GuardedOutput

class Target:
    def __init__(self): self.events=[]
    def key(self,key,down): self.events.append(('key',key['code'],down))
    def button(self,index,down): self.events.append(('button',index,down))
    def move(self,*value): self.events.append(('move',*value))
    def close(self): pass

def state(keys=(),buttons=0,x=0,y=0,sx=0,sy=0):
    return State.parse(dict(buttons=0,lx=0,ly=0,rx=0,ry=0,lt=0,rt=0,desktop=dict(keys=list(keys),buttons=buttons,x=x,y=y,scrollX=sx,scrollY=sy)))

class DesktopTests(unittest.TestCase):
    def test_chord_order_heartbeat_and_release(self):
        t=Target();d=DesktopOutput(t)
        value=state(['key:KeyA','key:ControlLeft'],1,10,20,1,2)
        d.write(value);d.write(value)
        self.assertEqual(t.events[:2],[('key','ControlLeft',True),('key','KeyA',True)])
        self.assertEqual(t.events.count(('move',10,20,1,2,1)),1)
        d.write(NEUTRAL)
        self.assertEqual(t.events[-3:],[('key','KeyA',False),('key','ControlLeft',False),('button',0,False)])
        d.write(state(x=3));self.assertEqual(t.events[-1],('move',3,0,0,0,0))
    def test_watchdog_releases_keyboard_and_mouse(self):
        now=[0];t=Target();g=GuardedOutput(DesktopOutput(t),clock=lambda:now[0])
        try:
            g.apply(state(['key:Space'],3),.3,g.generation);now[0]=.4;g.expire()
            self.assertIn(('key','Space',False),t.events)
            self.assertIn(('button',0,False),t.events)
            self.assertIn(('button',1,False),t.events)
        finally:g.close()
    def test_bad_keys_and_pointer_payloads_rejected(self):
        for kwargs in [dict(keys=['key:Exec']),dict(keys=['key:KeyA']*2),dict(buttons=True),dict(x=float('nan')),dict(sy=1e12)]:
            with self.assertRaises(ValueError):state(**kwargs)
        self.assertGreater(len(KEYS),75)
        self.assertTrue(state().is_neutral)
    def test_one_failed_key_release_does_not_leave_other_controls_held(self):
        class FaultyTarget(Target):
            failed = False
            def key(self,key,down):
                super().key(key,down)
                if not down and key['code'] == 'KeyA' and not self.failed:
                    self.failed=True
                    raise OSError('One native release failed')
        t=FaultyTarget();g=GuardedOutput(DesktopOutput(t))
        try:
            g.apply(state(['key:ControlLeft','key:KeyA'],3),g.clock()+1,g.generation)
            with self.assertRaises(RuntimeError):g.release()
            self.assertIn(('key','ControlLeft',False),t.events)
            self.assertIn(('button',0,False),t.events)
            self.assertIn(('button',1,False),t.events)
            self.assertTrue(g.closed)
        finally:g.close()
