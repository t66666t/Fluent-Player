"""Create local, deterministic subtitle fixtures using the app's licensed fonts."""
import json
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw, ImageFont


def main():
    root = Path('.artifacts/ocr-upgrade/fixture')
    root.mkdir(parents=True, exist_ok=True)
    font = ImageFont.truetype('assets/fonts/NotoSansCJKsc-Regular.otf', 58)
    phrases = ['字幕识别速度测试','保持原来的时间轴','模型下载完成后离线使用','每个区域分别保存字幕','', '最后一条字幕']
    for index in range(12):
        image = Image.new('RGBA',(1920,1080))
        draw = ImageDraw.Draw(image)
        text = phrases[index//2]
        if text:
            box=draw.textbbox((0,0),text,font=font)
            draw.text(((1920-(box[2]-box[0]))//2,895),text,font=font,
                      fill='white',stroke_width=3,stroke_fill='black')
        image.save(root/f'text_{index:02}.png')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',
        'testsrc2=size=1920x1080:rate=24','-framerate','1','-i',str(root/'text_%02d.png'),
        '-filter_complex','[0:v][1:v]overlay=eof_action=repeat:format=auto','-t','12','-an',
        '-c:v','libx264','-preset','ultrafast','-crf','20','-pix_fmt','yuv420p',str(root/'subtitles.mp4')],check=True)
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(root/'subtitles.mp4'),
        '-vf','hflip,vflip','-c:v','libx264','-preset','ultrafast','-crf','20',
        str(root/'mirrored.mp4')],check=True)
    for name, text in {'chinese':'简体中文字幕识别测试','japanese':'日本語の字幕テスト',
                       'korean':'한국어 자막 테스트','latin':'Français élève déjà vu','english':'English subtitle test'}.items():
        image=Image.new('RGB',(1280,160),(24,32,40))
        ImageDraw.Draw(image).text((24,38),text,font=font,fill='white')
        image.save(root/f'{name}.png')
    (root/'reference.json').write_text(json.dumps({'phrases':phrases},ensure_ascii=False,indent=2),encoding='utf-8')
    print(root/'subtitles.mp4')


if __name__=='__main__':
    main()
