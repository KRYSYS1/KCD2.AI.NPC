/*
 * KCD2 AI NPC — version.dll proxy (Phase 6b: MinHook + full D3D12 pipeline)
 *
 * Full D3D12 render pipeline for ImGui:
 *   - Command allocators per frame
 *   - Command list with proper render target transitions
 *   - RTV descriptor heap for back buffers
 *   - Proper frame indexing via GetCurrentBackBufferIndex
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <string>
#include <fstream>
#include <sstream>
#include <vector>
#include <mutex>
#include <thread>

#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "winhttp.lib")

#include "imgui.h"
#include "imgui_impl_dx12.h"
#include "imgui_impl_win32.h"
#include "minhook/include/MinHook.h"

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);

// ============================================================================
// version.dll forwarding (same as before, abbreviated)
// ============================================================================
static HMODULE g_real=nullptr;
typedef BOOL(WINAPI*PFN_GFVIA)(LPCSTR,DWORD,DWORD,LPVOID);
typedef BOOL(WINAPI*PFN_GFVIW)(LPCWSTR,DWORD,DWORD,LPVOID);
typedef BOOL(WINAPI*PFN_GFVIEA)(DWORD,LPCSTR,DWORD,DWORD,LPVOID);
typedef BOOL(WINAPI*PFN_GFVIEW)(DWORD,LPCWSTR,DWORD,DWORD,LPVOID);
typedef DWORD(WINAPI*PFN_GFVISA)(LPCSTR,LPDWORD);
typedef DWORD(WINAPI*PFN_GFVISW)(LPCWSTR,LPDWORD);
typedef DWORD(WINAPI*PFN_GFVISEA)(DWORD,LPCSTR,LPDWORD);
typedef DWORD(WINAPI*PFN_GFVISEW)(DWORD,LPCWSTR,LPDWORD);
typedef DWORD(WINAPI*PFN_VFFA)(DWORD,LPSTR,LPSTR,LPSTR,LPSTR,PUINT,LPSTR,PUINT);
typedef DWORD(WINAPI*PFN_VFFW)(DWORD,LPWSTR,LPWSTR,LPWSTR,LPWSTR,PUINT,LPWSTR,PUINT);
typedef DWORD(WINAPI*PFN_VIFA)(DWORD,LPSTR,LPSTR,LPSTR,LPSTR,LPSTR,LPSTR,PUINT);
typedef DWORD(WINAPI*PFN_VIFW)(DWORD,LPWSTR,LPWSTR,LPWSTR,LPWSTR,LPWSTR,LPWSTR,PUINT);
typedef DWORD(WINAPI*PFN_VLNA)(DWORD,LPSTR,DWORD);
typedef DWORD(WINAPI*PFN_VLNW)(DWORD,LPWSTR,DWORD);
typedef BOOL(WINAPI*PFN_VQVA)(LPCVOID,LPCSTR,LPVOID*,PUINT);
typedef BOOL(WINAPI*PFN_VQVW)(LPCVOID,LPCWSTR,LPVOID*,PUINT);
static PFN_GFVIA r1=0;static PFN_GFVIW r2=0;static PFN_GFVIEA r3=0;static PFN_GFVIEW r4=0;
static PFN_GFVISA r5=0;static PFN_GFVISW r6=0;static PFN_GFVISEA r7=0;static PFN_GFVISEW r8=0;
static PFN_VFFA r9=0;static PFN_VFFW r10=0;static PFN_VIFA r11=0;static PFN_VIFW r12=0;
static PFN_VLNA r13=0;static PFN_VLNW r14=0;static PFN_VQVA r15=0;static PFN_VQVW r16=0;
static void LoadRealDll(){char d[MAX_PATH];GetSystemDirectoryA(d,MAX_PATH);g_real=LoadLibraryA((std::string(d)+"\\version.dll").c_str());if(!g_real)return;
r1=(PFN_GFVIA)GetProcAddress(g_real,"GetFileVersionInfoA");r2=(PFN_GFVIW)GetProcAddress(g_real,"GetFileVersionInfoW");
r3=(PFN_GFVIEA)GetProcAddress(g_real,"GetFileVersionInfoExA");r4=(PFN_GFVIEW)GetProcAddress(g_real,"GetFileVersionInfoExW");
r5=(PFN_GFVISA)GetProcAddress(g_real,"GetFileVersionInfoSizeA");r6=(PFN_GFVISW)GetProcAddress(g_real,"GetFileVersionInfoSizeW");
r7=(PFN_GFVISEA)GetProcAddress(g_real,"GetFileVersionInfoSizeExA");r8=(PFN_GFVISEW)GetProcAddress(g_real,"GetFileVersionInfoSizeExW");
r9=(PFN_VFFA)GetProcAddress(g_real,"VerFindFileA");r10=(PFN_VFFW)GetProcAddress(g_real,"VerFindFileW");
r11=(PFN_VIFA)GetProcAddress(g_real,"VerInstallFileA");r12=(PFN_VIFW)GetProcAddress(g_real,"VerInstallFileW");
r13=(PFN_VLNA)GetProcAddress(g_real,"VerLanguageNameA");r14=(PFN_VLNW)GetProcAddress(g_real,"VerLanguageNameW");
r15=(PFN_VQVA)GetProcAddress(g_real,"VerQueryValueA");r16=(PFN_VQVW)GetProcAddress(g_real,"VerQueryValueW");}

// ============================================================================
// Helpers
// ============================================================================
static std::string g_gameDir;
static void WriteLog(const std::string& msg){std::ofstream f(g_gameDir+"\\kcd2_ainpc_plugin.log",std::ios::app);if(f.is_open())f<<msg<<"\n";}
static bool FileExists(const std::string& path){DWORD a=GetFileAttributesA(path.c_str());return a!=INVALID_FILE_ATTRIBUTES&&!(a&FILE_ATTRIBUTE_DIRECTORY);}
static std::string JsonEscape(const std::string& s){std::string o;for(unsigned char c:s){switch(c){case'"':o+="\\\"";break;case'\\':o+="\\\\";break;case'\n':o+="\\n";break;case'\r':break;default:o+=(char)c;}}return o;}
static std::string ExtractJsonString(const std::string& body,const std::string& key){size_t p=body.find("\""+key+"\"");if(p==std::string::npos)return"";p=body.find(':',p);if(p==std::string::npos)return"";p=body.find('"',p);if(p==std::string::npos)return"";++p;std::string o;while(p<body.size()){char c=body[p];if(c=='\\'&&p+1<body.size()){char n=body[p+1];if(n=='n')o+='\n';else if(n=='"')o+='"';else if(n=='\\')o+='\\';else o+=n;p+=2;}else if(c=='"')break;else{o+=c;++p;}}return o;}
static std::string HttpPostJson(const std::wstring& host,INTERNET_PORT port,const std::wstring& path,const std::string& body){HINTERNET s=WinHttpOpen(L"AINPC/2",WINHTTP_ACCESS_TYPE_NO_PROXY,0,0,0);if(!s)return"";HINTERNET c=WinHttpConnect(s,host.c_str(),port,0);HINTERNET rq=c?WinHttpOpenRequest(c,L"POST",path.c_str(),0,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,0):0;std::string res;if(rq){const wchar_t*h=L"Content-Type: application/json; charset=utf-8\r\n";if(WinHttpSendRequest(rq,h,(DWORD)-1,(LPVOID)body.data(),(DWORD)body.size(),(DWORD)body.size(),0)&&WinHttpReceiveResponse(rq,0)){for(;;){DWORD a=0;if(!WinHttpQueryDataAvailable(rq,&a)||!a)break;std::vector<char>buf(a);DWORD rd=0;WinHttpReadData(rq,buf.data(),a,&rd);res.append(buf.data(),rd);}}WinHttpCloseHandle(rq);}if(c)WinHttpCloseHandle(c);WinHttpCloseHandle(s);return res;}

// ============================================================================
// Overlay state
// ============================================================================
static bool g_inputOpen=false;static bool g_inputFocusNext=false;static char g_inputBuf[512]={};
static std::mutex g_mutex;static std::string g_subtitleText;static std::string g_subtitleNpc;static DWORD g_subtitleTick=0;static bool g_waiting=false;
static void SendToServer(const std::string& msg){g_waiting=true;std::thread([msg](){std::string body="{\"message\":\""+JsonEscape(msg)+"\"}";std::string resp=HttpPostJson(L"127.0.0.1",4999,L"/overlay/send",body);std::string name=ExtractJsonString(resp,"npc_name");std::string text=ExtractJsonString(resp,"response");{std::lock_guard<std::mutex>lk(g_mutex);g_subtitleNpc=name.empty()?"NPC":name;g_subtitleText=text.empty()?"[no response]":text;g_subtitleTick=GetTickCount();}g_waiting=false;WriteLog("[AI-NPC] Resp: "+g_subtitleNpc+": "+g_subtitleText.substr(0,80));}).detach();}

static void RenderOverlay(){
    ImGuiIO& io=ImGui::GetIO();float W=io.DisplaySize.x,H=io.DisplaySize.y;
    {std::lock_guard<std::mutex>lk(g_mutex);if(!g_subtitleText.empty()){DWORD el=GetTickCount()-g_subtitleTick;if(el<12000){float a=el>10000?(12000.f-el)/2000.f:1.f;ImGui::SetNextWindowPos(ImVec2(W*.5f,60),ImGuiCond_Always,ImVec2(.5f,0));ImGui::SetNextWindowBgAlpha(.75f*a);ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding,8);ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(16,10));ImGui::Begin("##sub",0,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_AlwaysAutoResize|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoNav|ImGuiWindowFlags_NoFocusOnAppearing);ImGui::PushStyleColor(ImGuiCol_Text,ImVec4(1,.85f,.4f,a));ImGui::Text("%s:",g_subtitleNpc.c_str());ImGui::PopStyleColor();ImGui::PushStyleColor(ImGuiCol_Text,ImVec4(1,1,1,a));ImGui::PushTextWrapPos(W*.6f);ImGui::TextWrapped("%s",g_subtitleText.c_str());ImGui::PopTextWrapPos();ImGui::PopStyleColor();ImGui::End();ImGui::PopStyleVar(2);}else g_subtitleText.clear();}}
    if(g_waiting&&!g_inputOpen){ImGui::SetNextWindowPos(ImVec2(W*.5f,H-80),ImGuiCond_Always,ImVec2(.5f,1));ImGui::SetNextWindowBgAlpha(.5f);ImGui::Begin("##w",0,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_AlwaysAutoResize|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoNav);ImGui::Text("...");ImGui::End();}
    if(g_inputOpen){float iw=W*.5f;if(iw<400)iw=400;ImGui::SetNextWindowPos(ImVec2(W*.5f,H-40),ImGuiCond_Always,ImVec2(.5f,1));ImGui::SetNextWindowSize(ImVec2(iw,0));ImGui::SetNextWindowBgAlpha(.8f);ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding,6);ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(12,8));ImGui::Begin("##in",0,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoNav);ImGui::PushItemWidth(-1);if(g_inputFocusNext){ImGui::SetKeyboardFocusHere();g_inputFocusNext=false;}if(ImGui::InputText("##m",g_inputBuf,sizeof(g_inputBuf),ImGuiInputTextFlags_EnterReturnsTrue)){if(g_inputBuf[0]){std::string m(g_inputBuf);g_inputBuf[0]=0;g_inputOpen=false;WriteLog("[AI-NPC] Send: "+m);SendToServer(m);}}ImGui::PopItemWidth();if(ImGui::IsKeyPressed(ImGuiKey_Escape)){g_inputOpen=false;g_inputBuf[0]=0;}ImGui::End();ImGui::PopStyleVar(2);}
}

// ============================================================================
// D3D12 Present hook with FULL render pipeline
// ============================================================================
typedef HRESULT(WINAPI*PFN_Present)(IDXGISwapChain3*,UINT,UINT);
static PFN_Present g_origPresent=nullptr;
static bool g_imguiInit=false;
static HWND g_gameHwnd=nullptr;
static ID3D12Device* g_dev=nullptr;
static ID3D12DescriptorHeap* g_srvHeap=nullptr;
static ID3D12DescriptorHeap* g_rtvHeap=nullptr;
static ID3D12CommandAllocator* g_cmdAlloc[3]={};
static ID3D12GraphicsCommandList* g_cmdList=nullptr;
static ID3D12Resource* g_backBuffers[3]={};
static UINT g_bufferCount=0;
static UINT g_rtvDescSize=0;
static WNDPROC g_origWndProc=nullptr;

static LRESULT CALLBACK HookWndProc(HWND h,UINT m,WPARAM w,LPARAM l){
    if(g_imguiInit&&g_inputOpen)ImGui_ImplWin32_WndProcHandler(h,m,w,l);
    if(g_inputOpen&&(m==WM_KEYDOWN||m==WM_KEYUP||m==WM_CHAR||m==WM_SYSKEYDOWN||m==WM_SYSKEYUP))return 0;
    return CallWindowProcA(g_origWndProc,h,m,w,l);
}

static HRESULT WINAPI HookedPresent(IDXGISwapChain3* sc,UINT sync,UINT flags){
    if(!g_imguiInit){
        DXGI_SWAP_CHAIN_DESC sd;sc->GetDesc(&sd);g_gameHwnd=sd.OutputWindow;
        g_bufferCount=sd.BufferCount;if(g_bufferCount>3)g_bufferCount=3;
        sc->GetDevice(IID_PPV_ARGS(&g_dev));

        // SRV heap for ImGui fonts
        D3D12_DESCRIPTOR_HEAP_DESC shd={};shd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;shd.NumDescriptors=1;shd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        g_dev->CreateDescriptorHeap(&shd,IID_PPV_ARGS(&g_srvHeap));

        // RTV heap for back buffers
        D3D12_DESCRIPTOR_HEAP_DESC rhd={};rhd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;rhd.NumDescriptors=g_bufferCount;
        g_dev->CreateDescriptorHeap(&rhd,IID_PPV_ARGS(&g_rtvHeap));
        g_rtvDescSize=g_dev->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);

        // Get back buffers and create RTVs
        D3D12_CPU_DESCRIPTOR_HANDLE rtvHandle=g_rtvHeap->GetCPUDescriptorHandleForHeapStart();
        for(UINT i=0;i<g_bufferCount;i++){
            sc->GetBuffer(i,IID_PPV_ARGS(&g_backBuffers[i]));
            g_dev->CreateRenderTargetView(g_backBuffers[i],nullptr,rtvHandle);
            rtvHandle.ptr+=g_rtvDescSize;
        }

        // Command allocators (one per frame)
        for(UINT i=0;i<g_bufferCount;i++)
            g_dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&g_cmdAlloc[i]));

        // Command list
        g_dev->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,g_cmdAlloc[0],nullptr,IID_PPV_ARGS(&g_cmdList));
        g_cmdList->Close();

        // ImGui init
        IMGUI_CHECKVERSION();ImGui::CreateContext();ImGui::GetIO().IniFilename=nullptr;
        ImGuiStyle&st=ImGui::GetStyle();st.Colors[ImGuiCol_WindowBg]=ImVec4(.05f,.05f,.08f,.85f);st.Colors[ImGuiCol_FrameBg]=ImVec4(.12f,.12f,.18f,.9f);st.Colors[ImGuiCol_Text]=ImVec4(.95f,.93f,.88f,1);
        ImGui_ImplWin32_Init(g_gameHwnd);
        ImGui_ImplDX12_Init(g_dev,g_bufferCount,sd.BufferDesc.Format,g_srvHeap,g_srvHeap->GetCPUDescriptorHandleForHeapStart(),g_srvHeap->GetGPUDescriptorHandleForHeapStart());

        g_origWndProc=(WNDPROC)SetWindowLongPtrA(g_gameHwnd,GWLP_WNDPROC,(LONG_PTR)HookWndProc);
        g_imguiInit=true;
        WriteLog("[AI-NPC] ImGui initialized (Phase 6b full pipeline)");
    }

    // Render ImGui
    UINT frameIdx=sc->GetCurrentBackBufferIndex();
    ID3D12CommandAllocator* alloc=g_cmdAlloc[frameIdx];
    alloc->Reset();
    g_cmdList->Reset(alloc,nullptr);

    // Transition: PRESENT -> RENDER_TARGET
    D3D12_RESOURCE_BARRIER barrier={};
    barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource=g_backBuffers[frameIdx];
    barrier.Transition.StateBefore=D3D12_RESOURCE_STATE_PRESENT;
    barrier.Transition.StateAfter=D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    g_cmdList->ResourceBarrier(1,&barrier);

    // Set render target
    D3D12_CPU_DESCRIPTOR_HANDLE rtvHandle=g_rtvHeap->GetCPUDescriptorHandleForHeapStart();
    rtvHandle.ptr+=frameIdx*g_rtvDescSize;
    g_cmdList->OMSetRenderTargets(1,&rtvHandle,FALSE,nullptr);

    // Set descriptor heap for ImGui
    ID3D12DescriptorHeap* heaps[]={g_srvHeap};
    g_cmdList->SetDescriptorHeaps(1,heaps);

    // ImGui frame
    ImGui_ImplDX12_NewFrame();ImGui_ImplWin32_NewFrame();ImGui::NewFrame();
    RenderOverlay();
    ImGui::Render();
    ImGui_ImplDX12_RenderDrawData(ImGui::GetDrawData(),g_cmdList);

    // Transition: RENDER_TARGET -> PRESENT
    barrier.Transition.StateBefore=D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter=D3D12_RESOURCE_STATE_PRESENT;
    g_cmdList->ResourceBarrier(1,&barrier);
    g_cmdList->Close();

    // Execute
    ID3D12CommandQueue* queue=nullptr;
    // Get command queue from device - we need to find it
    // Unfortunately D3D12 doesn't expose GetCommandQueue from swap chain directly
    // We'll create our own queue
    static ID3D12CommandQueue* g_queue=nullptr;
    if(!g_queue){D3D12_COMMAND_QUEUE_DESC qd={};qd.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;g_dev->CreateCommandQueue(&qd,IID_PPV_ARGS(&g_queue));}
    ID3D12CommandList* lists[]={(ID3D12CommandList*)g_cmdList};
    g_queue->ExecuteCommandLists(1,lists);

    return g_origPresent(sc,sync,flags);
}

// ============================================================================
// Hook installation (same MinHook approach)
// ============================================================================
static bool InstallPresentHook(){
    WNDCLASSA wc={};wc.lpfnWndProc=DefWindowProcA;wc.hInstance=GetModuleHandleA(0);wc.lpszClassName="AINPC_D";
    RegisterClassA(&wc);
    HWND hw=CreateWindowExA(0,"AINPC_D","",WS_OVERLAPPEDWINDOW,0,0,100,100,0,0,wc.hInstance,0);
    if(!hw)return false;
    ID3D12Device*dev=nullptr;if(FAILED(D3D12CreateDevice(0,D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&dev)))){DestroyWindow(hw);return false;}
    D3D12_COMMAND_QUEUE_DESC qd={};qd.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue*q=nullptr;dev->CreateCommandQueue(&qd,IID_PPV_ARGS(&q));if(!q){dev->Release();DestroyWindow(hw);return false;}
    IDXGIFactory4*f=nullptr;CreateDXGIFactory1(IID_PPV_ARGS(&f));if(!f){q->Release();dev->Release();DestroyWindow(hw);return false;}
    DXGI_SWAP_CHAIN_DESC1 scd={};scd.BufferCount=2;scd.Width=100;scd.Height=100;scd.Format=DXGI_FORMAT_R8G8B8A8_UNORM;scd.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;scd.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;scd.SampleDesc.Count=1;
    IDXGISwapChain1*sc1=nullptr;if(FAILED(f->CreateSwapChainForHwnd(q,hw,&scd,0,0,&sc1))||!sc1){f->Release();q->Release();dev->Release();DestroyWindow(hw);return false;}
    void*pPresent=(void*)(*(uintptr_t**)sc1)[8];
    sc1->Release();f->Release();q->Release();dev->Release();DestroyWindow(hw);UnregisterClassA("AINPC_D",GetModuleHandleA(0));
    if(MH_Initialize()!=MH_OK)return false;
    if(MH_CreateHook(pPresent,(void*)&HookedPresent,(void**)&g_origPresent)!=MH_OK)return false;
    if(MH_EnableHook(pPresent)!=MH_OK)return false;
    WriteLog("[AI-NPC] Present hook installed (MinHook + full pipeline)");
    return true;
}

static DWORD WINAPI ModThread(LPVOID){
    g_gameDir=[](){char b[MAX_PATH];GetModuleFileNameA(0,b,MAX_PATH);std::string s(b);auto p=s.rfind('\\');return p!=std::string::npos?s.substr(0,p):s;}();
    Sleep(3000);
    WriteLog("[AI-NPC] ===== Safe proxy mode =====");
    WriteLog("[AI-NPC] D3D12 Present/ImGui hook is disabled by default after confirmed GPU timeout crashes");
    if(!FileExists(g_gameDir+"\\ainpc_enable_d3d12_hook.flag")){WriteLog("[AI-NPC] Hook skipped. Create ainpc_enable_d3d12_hook.flag next to KingdomCome.exe to force the unsafe legacy hook.");return 0;}
    WriteLog("[AI-NPC] Unsafe legacy hook flag found");
    if(!InstallPresentHook()){WriteLog("[AI-NPC] FAILED");return 1;}
    bool vWas=false;
    while(true){SHORT st=GetAsyncKeyState('V');bool v=(st&0x8000)!=0;if(v&&!vWas&&!g_inputOpen){g_inputOpen=true;g_inputFocusNext=true;g_inputBuf[0]=0;WriteLog("[AI-NPC] V->open");}vWas=v;Sleep(50);}
}

BOOL APIENTRY DllMain(HMODULE hm,DWORD reason,LPVOID){if(reason==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(hm);LoadRealDll();CreateThread(0,0,ModThread,0,0,0);}return TRUE;}

// Exports
extern "C"{
BOOL WINAPI impl_GetFileVersionInfoA(LPCSTR a,DWORD b,DWORD c,LPVOID d){return r1?r1(a,b,c,d):FALSE;}
BOOL WINAPI impl_GetFileVersionInfoW(LPCWSTR a,DWORD b,DWORD c,LPVOID d){return r2?r2(a,b,c,d):FALSE;}
BOOL WINAPI impl_GetFileVersionInfoExA(DWORD f,LPCSTR a,DWORD b,DWORD c,LPVOID d){return r3?r3(f,a,b,c,d):FALSE;}
BOOL WINAPI impl_GetFileVersionInfoExW(DWORD f,LPCWSTR a,DWORD b,DWORD c,LPVOID d){return r4?r4(f,a,b,c,d):FALSE;}
DWORD WINAPI impl_GetFileVersionInfoSizeA(LPCSTR a,LPDWORD b){return r5?r5(a,b):0;}
DWORD WINAPI impl_GetFileVersionInfoSizeW(LPCWSTR a,LPDWORD b){return r6?r6(a,b):0;}
DWORD WINAPI impl_GetFileVersionInfoSizeExA(DWORD f,LPCSTR a,LPDWORD b){return r7?r7(f,a,b):0;}
DWORD WINAPI impl_GetFileVersionInfoSizeExW(DWORD f,LPCWSTR a,LPDWORD b){return r8?r8(f,a,b):0;}
DWORD WINAPI impl_VerFindFileA(DWORD f,LPSTR a,LPSTR b,LPSTR c,LPSTR d,PUINT e,LPSTR g,PUINT h){return r9?r9(f,a,b,c,d,e,g,h):0;}
DWORD WINAPI impl_VerFindFileW(DWORD f,LPWSTR a,LPWSTR b,LPWSTR c,LPWSTR d,PUINT e,LPWSTR g,PUINT h){return r10?r10(f,a,b,c,d,e,g,h):0;}
DWORD WINAPI impl_VerInstallFileA(DWORD f,LPSTR a,LPSTR b,LPSTR c,LPSTR d,LPSTR e,LPSTR g,PUINT h){return r11?r11(f,a,b,c,d,e,g,h):0;}
DWORD WINAPI impl_VerInstallFileW(DWORD f,LPWSTR a,LPWSTR b,LPWSTR c,LPWSTR d,LPWSTR e,LPWSTR g,PUINT h){return r12?r12(f,a,b,c,d,e,g,h):0;}
DWORD WINAPI impl_VerLanguageNameA(DWORD a,LPSTR b,DWORD c){return r13?r13(a,b,c):0;}
DWORD WINAPI impl_VerLanguageNameW(DWORD a,LPWSTR b,DWORD c){return r14?r14(a,b,c):0;}
BOOL WINAPI impl_VerQueryValueA(LPCVOID a,LPCSTR b,LPVOID*c,PUINT d){return r15?r15(a,b,c,d):FALSE;}
BOOL WINAPI impl_VerQueryValueW(LPCVOID a,LPCWSTR b,LPVOID*c,PUINT d){return r16?r16(a,b,c,d):FALSE;}
}
