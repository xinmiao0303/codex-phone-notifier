#requires -Version 5.1
# 基于 vendored Lucide bell-ring SVG 的原始路径绘制，原许可见 assets/LUCIDE-LICENSE.txt。
$ErrorActionPreference = 'Stop'
if (-not ('NotifierIconBuilder' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Collections.Generic;
public static class NotifierIconBuilder {
    static GraphicsPath Rounded(float x,float y,float w,float h,float r) {
        GraphicsPath p=new GraphicsPath();
        p.AddArc(x,y,r*2,r*2,180,90); p.AddArc(x+w-r*2,y,r*2,r*2,270,90);
        p.AddArc(x+w-r*2,y+h-r*2,r*2,r*2,0,90); p.AddArc(x,y+h-r*2,r*2,r*2,90,90); p.CloseFigure(); return p;
    }
    static Bitmap Frame(int size) {
        int render=size*4; Bitmap high=new Bitmap(render,render,PixelFormat.Format32bppArgb);
        using(Graphics g=Graphics.FromImage(high)) {
            g.SmoothingMode=SmoothingMode.AntiAlias; g.Clear(Color.Transparent); g.ScaleTransform(render/256f,render/256f);
            using(GraphicsPath tile=Rounded(16,16,224,224,48))
            using(LinearGradientBrush fill=new LinearGradientBrush(new PointF(32,24),new PointF(220,232),Color.FromArgb(54,117,239),Color.FromArgb(28,61,161))) g.FillPath(fill,tile);
            GraphicsState state=g.Save(); g.TranslateTransform(44,39); g.ScaleTransform(7,7);
            using(Pen pen=new Pen(Color.White,1.85f)) {
                pen.StartCap=LineCap.Round; pen.EndCap=LineCap.Round; pen.LineJoin=LineJoin.Round;
                // 对应 Lucide SVG 的四条路径，SVG 的弧以 GDI+ 等价圆弧表达。
                g.DrawArc(pen,10,18,4,4,150,-120);
                using(GraphicsPath right=new GraphicsPath()) { right.AddBezier(22,8,22,5.7f,21.2f,3.7f,20,2); g.DrawPath(pen,right); }
                using(GraphicsPath body=new GraphicsPath()) {
                    body.AddArc(3,15,2,2,222.4f,-132.4f); body.AddLine(4,17,20,17);
                    body.AddArc(19,15,2,2,90,-132.3f); body.AddBezier(20.74f,15.327f,19.41f,13.956f,18,12.499f,18,8);
                    body.AddArc(6,2,12,12,0,-180); body.AddBezier(6,8,6,12.499f,4.589f,13.956f,3.262f,15.326f); g.DrawPath(pen,body);
                }
                using(GraphicsPath left=new GraphicsPath()) { left.AddBezier(4,2,2.8f,3.7f,2,5.7f,2,8); g.DrawPath(pen,left); }
            }
            g.Restore(state);
            using(SolidBrush rim=new SolidBrush(Color.FromArgb(29,65,174))) g.FillEllipse(rim,178,178,48,48);
            using(SolidBrush dot=new SolidBrush(Color.FromArgb(80,222,163))) g.FillEllipse(dot,184,184,36,36);
        }
        Bitmap final=new Bitmap(size,size,PixelFormat.Format32bppArgb);
        using(Graphics g=Graphics.FromImage(final)) { g.InterpolationMode=InterpolationMode.HighQualityBicubic; g.CompositingQuality=CompositingQuality.HighQuality; g.DrawImage(high,new Rectangle(0,0,size,size)); }
        high.Dispose(); return final;
    }
    public static void Write(string icon,string png) {
        int[] sizes={16,24,32,48,64,128,256}; List<byte[]> frames=new List<byte[]>();
        foreach(int size in sizes) using(Bitmap image=Frame(size)) using(MemoryStream stream=new MemoryStream()) { image.Save(stream,ImageFormat.Png); frames.Add(stream.ToArray()); if(size==256) image.Save(png,ImageFormat.Png); }
        using(BinaryWriter writer=new BinaryWriter(File.Create(icon))) {
            writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)sizes.Length);
            int offset=6+sizes.Length*16;
            for(int i=0;i<sizes.Length;i++) { writer.Write((byte)(sizes[i]==256?0:sizes[i])); writer.Write((byte)(sizes[i]==256?0:sizes[i])); writer.Write((byte)0); writer.Write((byte)0); writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(frames[i].Length); writer.Write(offset); offset+=frames[i].Length; }
            foreach(byte[] frame in frames) writer.Write(frame);
        }
    }
}
"@
}
[NotifierIconBuilder]::Write((Join-Path $PSScriptRoot 'assets/notifier.ico'),(Join-Path $PSScriptRoot 'assets/notifier.png'))
