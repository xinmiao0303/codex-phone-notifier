#requires -Version 5.1
# 将 Lobe Icons 的 OpenAI 结形 SVG 与 Lucide 铃铛组合为透明图标。
# 原始资产和许可保存在 assets；商标权不因图标库的开源许可转移。
$ErrorActionPreference = 'Stop'
if (-not ('NotifierIconBuilder' -as [type])) {
$framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/WPF'
if (-not (Test-Path -LiteralPath $framework)) { $framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/WPF' }
Add-Type -ReferencedAssemblies @('System.Drawing', (Join-Path $framework 'PresentationCore.dll'), (Join-Path $framework 'WindowsBase.dll')) -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Collections.Generic;
public static class NotifierIconBuilder {
    // WPF 解析 SVG 路径，展开圆弧后交给 GDI+；只用于构建，不增加软件运行依赖。
    static GraphicsPath Knot(string data) {
        System.Windows.Media.PathGeometry geometry=System.Windows.Media.Geometry.Parse("F0 " + data).GetFlattenedPathGeometry(0.002, System.Windows.Media.ToleranceType.Absolute);
        GraphicsPath path=new GraphicsPath(FillMode.Alternate);
        foreach(System.Windows.Media.PathFigure figure in geometry.Figures) {
            List<PointF> points=new List<PointF>();
            points.Add(new PointF((float)figure.StartPoint.X,(float)figure.StartPoint.Y));
            foreach(System.Windows.Media.PathSegment segment in figure.Segments) {
                System.Windows.Media.PolyLineSegment poly=segment as System.Windows.Media.PolyLineSegment;
                if(poly!=null) foreach(System.Windows.Point point in poly.Points) points.Add(new PointF((float)point.X,(float)point.Y));
                else {
                    System.Windows.Media.LineSegment line=segment as System.Windows.Media.LineSegment;
                    if(line==null) throw new InvalidOperationException("SVG 包含未展开的路径。");
                    points.Add(new PointF((float)line.Point.X,(float)line.Point.Y));
                }
            }
            if(figure.IsClosed) path.AddPolygon(points.ToArray()); else path.AddLines(points.ToArray());
        }
        return path;
    }
    static GraphicsPath Bell() {
        GraphicsPath body=new GraphicsPath();
        // Lucide bell-ring 的铃身，去掉两侧振铃线以保证小尺寸清晰。
        body.AddArc(3,15,2,2,222.4f,-132.4f); body.AddLine(4,17,20,17);
        body.AddArc(19,15,2,2,90,-132.3f); body.AddBezier(20.74f,15.327f,19.41f,13.956f,18,12.499f,18,8);
        body.AddArc(6,2,12,12,0,-180); body.AddBezier(6,8,6,12.499f,4.589f,13.956f,3.262f,15.326f); body.CloseFigure();
        return body;
    }
    static Pen Outline(Color color,float width) { Pen pen=new Pen(color,width); pen.StartCap=LineCap.Round; pen.EndCap=LineCap.Round; pen.LineJoin=LineJoin.Round; return pen; }
    static Bitmap Frame(int size,string data,bool taskbar) {
        int render=size*4; Bitmap high=new Bitmap(render,render,PixelFormat.Format32bppArgb);
        using(Graphics g=Graphics.FromImage(high)) {
            g.SmoothingMode=SmoothingMode.AntiAlias; g.Clear(Color.Transparent); g.ScaleTransform(render/256f,render/256f);
            GraphicsState main=g.Save(); g.TranslateTransform(taskbar?3:7,taskbar?2:6); g.ScaleTransform(taskbar?10:9.5f,taskbar?10:9.5f);
            using(GraphicsPath knot=Knot(data))
            using(Pen edge=Outline(Color.FromArgb(245,245,245),0.28f))
            using(SolidBrush fill=new SolidBrush(taskbar?Color.FromArgb(248,250,252):Color.FromArgb(24,24,24))) { if(!taskbar) g.DrawPath(edge,knot); g.FillPath(fill,knot); }
            g.Restore(main);
            // 铃铛直接叠放在右下角；白色轮廓帮助它与主体分开，没有圆形或方形底。
            GraphicsState corner=g.Save(); g.TranslateTransform(taskbar?161:154,taskbar?160:158); g.ScaleTransform(4,4);
            using(GraphicsPath bell=Bell())
            using(Pen halo=Outline(taskbar?Color.FromArgb(35,39,45):Color.FromArgb(250,250,250),3.1f))
            using(Pen ink=Outline(Color.FromArgb(60,42,15),1.15f))
            using(SolidBrush gold=new SolidBrush(taskbar?Color.FromArgb(255,204,92):Color.FromArgb(245,177,45))) {
                g.DrawPath(halo,bell); g.DrawArc(halo,10,18,4,4,150,-120);
                g.FillPath(gold,bell); g.DrawPath(ink,bell); g.DrawArc(ink,10,18,4,4,150,-120);
            }
            g.Restore(corner);
        }
        Bitmap final=new Bitmap(size,size,PixelFormat.Format32bppArgb);
        using(Graphics g=Graphics.FromImage(final)) { g.InterpolationMode=InterpolationMode.HighQualityBicubic; g.CompositingQuality=CompositingQuality.HighQuality; g.DrawImage(high,new Rectangle(0,0,size,size)); }
        // 去掉缩小采样产生的近乎透明杂点，保持画布四角完全透明。
        for(int y=0;y<size;y++) for(int x=0;x<size;x++) if(final.GetPixel(x,y).A<16) final.SetPixel(x,y,Color.Transparent);
        high.Dispose(); return final;
    }
    public static void Write(string icon,string png,string data,bool taskbar) {
        int[] sizes={16,24,32,48,64,128,256}; List<byte[]> frames=new List<byte[]>();
        foreach(int size in sizes) using(Bitmap image=Frame(size,data,taskbar)) using(MemoryStream stream=new MemoryStream()) { image.Save(stream,ImageFormat.Png); frames.Add(stream.ToArray()); if(size==256) image.Save(png,ImageFormat.Png); }
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
[xml]$svg = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'assets/openai.svg') -Raw
$knotData = $svg.svg.path.GetAttribute('d')
[NotifierIconBuilder]::Write((Join-Path $PSScriptRoot 'assets/notifier.ico'),(Join-Path $PSScriptRoot 'assets/notifier.png'),$knotData,$false)
[NotifierIconBuilder]::Write((Join-Path $PSScriptRoot 'assets/taskbar-light.ico'),(Join-Path $PSScriptRoot 'assets/taskbar-light.png'),$knotData,$true)
