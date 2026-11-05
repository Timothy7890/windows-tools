// conpty relay: hosts a command in a side-loaded conpty.dll/OpenConsole and pipes raw bytes over stdio,
// so an `ssh -T` session avoids sshd's inbox conhost. Resize arrives in-band as ESC ] 7719 ; cols ; rows BEL.
// relay.exe lives next to conpty.dll and OpenConsole.exe.
// usage: relay.exe <cols> <rows> <commandline>
using System;using System.IO;using System.Text;using System.Text.RegularExpressions;using System.Threading;using System.Runtime.InteropServices;using Microsoft.Win32.SafeHandles;
class R{
[StructLayout(LayoutKind.Sequential)]struct COORD{public short X,Y;}
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct SI{public int cb;public string a,b,c;public int d,e,f,g,h,i,j,flags;public short k,l;public IntPtr m,inp,outp,err;}
[StructLayout(LayoutKind.Sequential)]struct SIEX{public SI si;public IntPtr attr;}
[StructLayout(LayoutKind.Sequential)]struct PI{public IntPtr p,t;public int pid,tid;}
[DllImport("kernel32",SetLastError=true,CharSet=CharSet.Unicode)]static extern IntPtr LoadLibraryW(string f);
[DllImport("kernel32",SetLastError=true)]static extern bool CreatePipe(out IntPtr r,out IntPtr w,IntPtr s,int n);
[DllImport("kernel32",SetLastError=true)]static extern bool InitializeProcThreadAttributeList(IntPtr l,int c,int f,ref IntPtr sz);
[DllImport("kernel32",SetLastError=true)]static extern bool UpdateProcThreadAttribute(IntPtr l,int f,IntPtr a,IntPtr v,IntPtr sz,IntPtr p,IntPtr r);
[DllImport("kernel32",SetLastError=true,CharSet=CharSet.Unicode)]static extern bool CreateProcessW(string app,string cmd,IntPtr pa,IntPtr ta,bool inh,int fl,IntPtr env,string cwd,ref SIEX si,out PI pi);
[DllImport("kernel32")]static extern int WaitForSingleObject(IntPtr h,int ms);
[DllImport("kernel32")]static extern bool CloseHandle(IntPtr h);
[DllImport("kernel32")]static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32",SetLastError=true)]static extern bool PeekNamedPipe(IntPtr h,IntPtr b,int n,IntPtr r,out int av,IntPtr l);
[DllImport("kernel32",SetLastError=true)]static extern bool ReadFile(IntPtr h,byte[] b,int n,out int got,IntPtr o);
[DllImport("conpty.dll",PreserveSig=true)]static extern int CreatePseudoConsole(COORD c,IntPtr i,IntPtr o,int f,out IntPtr h);
[DllImport("conpty.dll",PreserveSig=true)]static extern int ResizePseudoConsole(IntPtr h,COORD c);
[DllImport("conpty.dll",PreserveSig=true)]static extern void ClosePseudoConsole(IntPtr h);
static IntPtr pc;
static void Quit(int c){try{ClosePseudoConsole(pc);}catch{}Environment.Exit(c);}
static int Main(string[] a){
 string cd=Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
 if(LoadLibraryW(Path.Combine(cd,"conpty.dll"))==IntPtr.Zero){Console.Error.WriteLine("cannot load conpty.dll from "+cd);return 2;}
 Environment.SetEnvironmentVariable("PSMUX_CONPTY_DIR",cd);
 IntPtr inR,inW,outR,outW;CreatePipe(out inR,out inW,IntPtr.Zero,0);CreatePipe(out outR,out outW,IntPtr.Zero,0);
 int hr=CreatePseudoConsole(new COORD{X=short.Parse(a[0]),Y=short.Parse(a[1])},inR,outW,0,out pc);if(hr!=0){Console.Error.WriteLine("CreatePseudoConsole hr="+hr);return 3;}
 CloseHandle(inR);CloseHandle(outW);
 IntPtr n=IntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref n);IntPtr l=Marshal.AllocHGlobal(n);InitializeProcThreadAttributeList(l,1,0,ref n);
 UpdateProcThreadAttribute(l,0,(IntPtr)0x20016,pc,(IntPtr)IntPtr.Size,IntPtr.Zero,IntPtr.Zero);
 SIEX si=new SIEX();si.si.cb=Marshal.SizeOf(typeof(SIEX));si.si.flags=0x100;si.attr=l;PI pi;
 if(!CreateProcessW(null,a[2],IntPtr.Zero,IntPtr.Zero,false,0x80400,IntPtr.Zero,null,ref si,out pi)){Console.Error.WriteLine("CreateProcess err "+Marshal.GetLastWin32Error());return 4;}
 var so=Console.OpenStandardOutput();
 var fo=new FileStream(new SafeFileHandle(outR,true),FileAccess.Read,4096,false);var fi=new FileStream(new SafeFileHandle(inW,true),FileAccess.Write,4096,false);
 var t1=new Thread(()=>{var b=new byte[65536];try{int k;while((k=fo.Read(b,0,b.Length))>0){so.Write(b,0,k);so.Flush();}}catch{Quit(0);}});t1.IsBackground=true;t1.Start();
 var rx=new Regex("\x1b\\]7719;(\\d+);(\\d+)\x07");var lat=Encoding.GetEncoding(28591);
 var t2=new Thread(()=>{var b=new byte[8192];IntPtr h=GetStdHandle(-10);int av,got;try{while(true){
   if(!PeekNamedPipe(h,IntPtr.Zero,0,IntPtr.Zero,out av,IntPtr.Zero))Quit(0);
   if(av==0){Thread.Sleep(4);continue;}
   if(!ReadFile(h,b,Math.Min(av,b.Length),out got,IntPtr.Zero)||got==0)Quit(0);
   string s=lat.GetString(b,0,got);
   foreach(Match m in rx.Matches(s))ResizePseudoConsole(pc,new COORD{X=short.Parse(m.Groups[1].Value),Y=short.Parse(m.Groups[2].Value)});
   var o=lat.GetBytes(rx.Replace(s,""));if(o.Length>0){fi.Write(o,0,o.Length);fi.Flush();}
 }}catch{Quit(0);}});t2.IsBackground=true;t2.Start();
 WaitForSingleObject(pi.p,-1);Thread.Sleep(200);Quit(0);return 0;
}}
