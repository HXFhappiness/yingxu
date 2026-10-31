"""Converter regressions: fixed format, bounded admission retries and no partial writes."""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import video2yxv as converter
from mjpeg_ref.jpeg import ProfileError
from mjpeg_ref.vectors import make_jpeg
from mjpeg_ref.container import inspect_container

class ConverterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.flat=make_jpeg()
        cls.slow=make_jpeg(150000,style='frontloaded')
    def test_explicit_encoder_format_and_gain(self):
        commands=[]
        with tempfile.TemporaryDirectory() as tmp, patch.object(converter,'find_ffmpeg',return_value='ffmpeg'), patch.object(converter,'run',side_effect=commands.append):
            converter.transcode('source.mkv',tmp,640,480,24,4,0.5)
        video,audio=commands
        self.assertEqual(video[video.index('-pix_fmt')+1],'yuvj420p')
        self.assertEqual(video[video.index('-huffman')+1],'default')
        self.assertIn('out_color_matrix=bt601',video[video.index('-vf')+1])
        self.assertEqual(audio[audio.index('-ar')+1],'48000')
        self.assertEqual(audio[audio.index('-af')+1],'volume=0.5')
    def encoded(self,first,second=None):
        state={'calls':0}
        def transcode(src,tmp,width,height,fps,quality,gain):
            state['calls']+=1
            jpg=first if state['calls']==1 or second is None else second
            video,audio=Path(tmp)/'v.mjpeg',Path(tmp)/'a.pcm'
            video.write_bytes(jpg); audio.write_bytes(bytes(8000))
            return str(video),str(audio)
        return transcode,state
    def test_retry_rejected_cycle_frame(self):
        encode,state=self.encoded(self.slow,self.flat)
        version=type('Result',(),{'stdout':'ffmpeg test\n'})()
        with tempfile.TemporaryDirectory() as tmp, patch.object(converter,'transcode',side_effect=encode), patch.object(converter,'find_ffmpeg',return_value='ffmpeg'), patch.object(converter,'run',return_value=version):
            out=Path(tmp)/'clip.yxv'
            report=converter.convert('source',out)
            self.assertEqual(state['calls'],2)
            self.assertEqual(report['attempts'][0]['error_code'],'CORE_CYCLES')
            self.assertTrue(report['attempts'][1]['accepted'])
            self.assertEqual(inspect_container(out.read_bytes())['frames'],1)
    def test_rejection_preserves_existing_output(self):
        encode,state=self.encoded(self.slow)
        with tempfile.TemporaryDirectory() as tmp, patch.object(converter,'transcode',side_effect=encode):
            out=Path(tmp)/'clip.yxv'; out.write_bytes(b'old user output')
            with self.assertRaises(ProfileError) as caught:
                converter.convert('source',out,quality=31)
            self.assertEqual(caught.exception.code,'CORE_CYCLES')
            self.assertEqual(state['calls'],1)
            self.assertEqual(out.read_bytes(),b'old user output')
    def test_demo_duration_limit(self):
        encode,_=self.encoded(self.flat)
        with tempfile.TemporaryDirectory() as tmp, patch.object(converter,'transcode',side_effect=encode), patch.object(converter,'split_mjpeg',return_value=[self.flat]*505):
            with self.assertRaises(ProfileError) as caught:
                converter.convert('source',Path(tmp)/'clip.yxv')
            self.assertEqual(caught.exception.code,'DEMO_DURATION')
    def test_reject_unapproved_fallback(self):
        with self.assertRaises(ProfileError) as caught:
            converter.convert('source','unused',fps=15)
        self.assertEqual(caught.exception.code,'YXV_PROFILE')
    def test_bad_file_never_opens_volume(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'bad.yxv'; path.write_bytes(b'bad')
            with self.assertRaises(ProfileError) as caught:
                converter.write_card(path,'E')
            self.assertEqual(caught.exception.code,'YXV_SIZE')

if __name__=='__main__':
    unittest.main()
