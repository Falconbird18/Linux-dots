"""Exercise installation in isolated homes; never touch real packages/services."""
import ast
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        stub = self.home / 'test-bin'
        stub.mkdir()
        # An unrelated real desktop app must not affect isolated-home tests.
        (stub / 'pgrep').write_text('#!/bin/sh\nexit 1\n')
        (stub / 'pgrep').chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_DATA_HOME=str(self.home / '.local/share'),
                        XDG_STATE_HOME=str(self.home / '.local/state'),
                        PATH=f'{stub}:{os.environ["PATH"]}')

    def run_install(self, *args, answers=""):
        return subprocess.run(['bash', str(REPO / 'install.sh'), *args],
                              env=self.env, input=answers, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=True).stdout

    def test_wrapper_embedded_python(self):
        wrapper = (REPO / '.local/bin/mscore').read_text()
        embedded = wrapper.split("<<'PY_SCALE'\n", 1)[1].split('\nPY_SCALE', 1)[0]
        ast.parse(embedded)

    def full_choices(self, device='2', display='2', selected='y', confirm='y'):
        # device, full setup, display, desktop/keyd/audio, four app groups,
        # gaming, wallpapers, final review.
        return '\n'.join([device, '1', display] + [selected] * 7 + ['n', selected, confirm]) + '\n'

    def sync_choices(self, device='2', display='1'):
        return '\n'.join([device, '2', display, 'y', 'y']) + '\n'

    def test_profiles_and_dry_run(self):
        for device, profile in [('1', 'surface'), ('2', 'hp'), ('3', 'other')]:
            out = self.run_install('--dry-run', answers=self.full_choices(device))
            self.assertIn(f'Device:        {profile}', out)
            self.assertIn('alsa-plugins', out)
            self.assertIn('ttf-google-fonts-typewolf', out)
            self.assertIn('musescore-bin', out)
            self.assertIn('register and verify all Dragonfly', out)
            self.assertFalse((self.home / '.config').exists())
            self.assertFalse((self.home / '.local').exists())

    def test_declined_components_are_excluded(self):
        out = self.run_install('--dry-run', answers=self.full_choices(selected='n'))
        packages = out.split('Would install Arch packages:', 1)[1].split('Installing configuration', 1)[0]
        for name in ['firefox', 'keyd', 'musescore-bin', 'dragonfly', 'hyprland-git', 'blender-bin', 'wine']:
            self.assertNotIn(name, packages)
        self.assertNotIn('Would register', out)
        self.assertNotIn('Would merge MuseScore', out)
        self.assertNotIn('backgrounds/Tempora', out)

    def test_cancel_and_eof_leave_home_untouched(self):
        out = self.run_install(answers=self.full_choices(confirm='n'))
        self.assertIn('Cancelled', out)
        self.assertFalse((self.home / '.config').exists())
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_install('--dry-run')
        self.assertFalse((self.home / '.config').exists())

    def test_unattended_preview(self):
        out = self.run_install('--yes', '--dry-run')
        self.assertIn('firefox', out)
        self.assertIn('zotero-bin', out)
        self.assertIn('blender-bin', out)
        self.assertNotIn('winetricks', out)
        self.assertFalse((self.home / '.config').exists())

    def test_merge_backup_and_repeated_sync(self):
        config = self.home / '.config'
        ini = config / 'MuseScore/MuseScore4.ini'
        ini.parent.mkdir(parents=True)
        original = '[ui]\ntheme=dark\n[io]\noutputDevice=default\nmidi\\enableInput=false\n'
        ini.write_text(original)
        outputs = config / 'hypr/dms/outputs.lua'
        outputs.parent.mkdir(parents=True)
        outputs.write_text('-- my laptop display\n')
        unrelated = config / 'keep-me'
        unrelated.write_text('personal')
        args = ()
        self.run_install(*args, answers=self.sync_choices())
        self.assertIn('outputDevice=pulse', ini.read_text())
        self.assertNotIn('outputDevice=default', ini.read_text())
        self.assertIn('theme=dark', ini.read_text())
        self.assertIn('midi\\enableInput=false', ini.read_text())
        self.assertEqual(outputs.read_text(), '-- my laptop display\n')
        self.assertEqual(unrelated.read_text(), 'personal')
        backups = list((self.home / '.local/state/dotfiles/backups').glob('*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'config/MuseScore/MuseScore4.ini').read_text(), original)
        self.run_install(*args, answers=self.sync_choices())
        self.assertEqual(list((self.home / '.local/state/dotfiles/backups').glob('*')), backups)
        self.run_install(*args, answers=self.sync_choices(display='3'))
        self.assertIn('scale = "auto"', outputs.read_text())

    def test_terminal_sync_preserves_generated_dms_palette(self):
        config = self.home / '.config'
        kitty = config / 'kitty'
        kitty.mkdir(parents=True)
        generated = {
            'dank-theme.conf': 'background #123456\ncolor4 #abcdef\n',
            'dank-tabs.conf': 'active_tab_background #abcdef\n',
        }
        for name, content in generated.items():
            (kitty / name).write_text(content)
        (kitty / 'kitty.conf').write_text('font_size 11\n')
        (config / 'starship.toml').write_text('add_newline = false\n')
        self.run_install(answers=self.sync_choices())
        for relative in ['kitty/kitty.conf', 'kitty/current-theme.conf',
                         'starship.toml', 'fish/config.fish']:
            self.assertEqual((config / relative).read_bytes(),
                             (REPO / '.config' / relative).read_bytes())
        for name, content in generated.items():
            self.assertEqual((kitty / name).read_text(), content)
        backups = list((self.home / '.local/state/dotfiles/backups').glob('*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'config/kitty/kitty.conf').read_text(),
                         'font_size 11\n')
        self.run_install(answers=self.sync_choices())
        self.assertEqual(list((self.home / '.local/state/dotfiles/backups').glob('*')),
                         backups)
        for name, content in generated.items():
            self.assertEqual((kitty / name).read_text(), content)

    def test_saved_hp_display(self):
        self.run_install(answers=self.sync_choices(display='2'))
        outputs = (self.home / '.config/hypr/dms/outputs.lua').read_text()
        self.assertIn('1920x1080@60.164', outputs)
        self.assertIn('scale = 1', outputs)
        self.assertNotIn('2880x1920', outputs)

    def test_surface_display_in_new_home(self):
        self.run_install(answers=self.sync_choices(device='1'))
        outputs = self.home / '.config/hypr/dms/outputs.lua'
        self.assertIn('2880x1920', outputs.read_text())
        self.assertTrue((self.home / '.local/bin/mscore').is_file())


if __name__ == '__main__':
    unittest.main()
