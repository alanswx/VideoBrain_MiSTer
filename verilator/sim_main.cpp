// ---------------------------------------------------------------------------
// Graphical Verilator harness for the VideoBrain core: SDL2 + ImGui.
//
// Shares sim.v and the sim/ support layer with the headless build. Use
// "make headless" for batch runs; this one is always interactive.
// ---------------------------------------------------------------------------

#include <verilated.h>
#include "Vtop.h"
#include "Vtop___024root.h"

#include <string>

// sim_input.cpp expects this global.
bool headless = false;

#include "imgui.h"
#ifndef _MSC_VER
#include <stdio.h>
#include <SDL.h>
#include <SDL_opengl.h>
#else
#define WIN32
#include <dinput.h>
#endif

#include "sim_console.h"
#include "sim_bus.h"
#include "sim_video.h"
#include "sim_input.h"
#include "sim_clock.h"

#include "../imgui/imgui_memory_editor.h"
#include <verilated_vcd_c.h>
#include "../imgui/ImGuiFileDialog.h"

// Accessors into the netlist. Names come from the VHDL through ghdl synth.
#define CORE(sig) (top->rootp->top__DOT__core__DOT__##sig)
#define CPU(sig)  (top->rootp->top__DOT__core__DOT__u_cpu__DOT__##sig)
#define BUS(sig)  (top->rootp->top__DOT__core__DOT__u_sys_bus__DOT__##sig)
#define UVR(sig)  (top->rootp->top__DOT__core__DOT__u_sys_bus__DOT__u_uv201_regs__DOT__##sig)
#define FET(sig)  (top->rootp->top__DOT__core__DOT__u_fetcher__DOT__##sig)
#define TOP(sig)  (top->rootp->top__DOT__##sig)
#define REN(sig)  (top->rootp->top__DOT__core__DOT__u_render__DOT__##sig)

// Simulation control
int  batchSize = 200000;
bool run_enable = false;
bool single_step = false;
bool multi_step = false;
int  multi_step_amount = 1024;

const char* windowTitle = "Verilator Sim: VideoBrain";
const char* windowTitle_Control = "Simulation control";
const char* windowTitle_DebugLog = "Debug log";
const char* windowTitle_Video = "Video output";
const char* windowTitle_Trace = "Trace/VCD control";
bool showDebugLog = true;
DebugConsole console;
MemoryEditor mem_edit;

SimBus bus(console);
SimInput input(12, console);

// The UV201 active raster: 228 BRCLK per line less 39 of HBLANK, and the
// visible lines of one field.
#define VGA_WIDTH   189
#define VGA_HEIGHT  246
#define VGA_ROTATE  0
#define VGA_SCALE_X vga_scale
#define VGA_SCALE_Y vga_scale
SimVideo video(VGA_WIDTH, VGA_HEIGHT, VGA_ROTATE);
float vga_scale = 3;

Vtop* top = NULL;

vluint64_t main_time = 0;
double sc_time_stamp() { return (double)main_time; }

SimClock clk_sys(1);

VerilatedVcdC* tfp = new VerilatedVcdC;
bool Trace = false;
char Trace_File[30] = "sim.vcd";

void resetSim() {
    main_time = 0;
    clk_sys.Reset();
    top->reset = 1;
}

int verilate() {
    if (!Verilated::gotFinish()) {

        clk_sys.Tick();
        top->clk_sys = clk_sys.clk;

        if (clk_sys.clk != clk_sys.old) {
            if (clk_sys.clk) {
                input.BeforeEval();
                bus.BeforeEval();
            }
            top->eval();
            if (Trace) {
                if (!tfp->isOpen()) tfp->open(Trace_File);
                tfp->dump(main_time);
            }
            if (clk_sys.clk) bus.AfterEval();
        }

        // One pixel per BRCLK, marked by ce_pix.
        if (clk_sys.IsRising() && top->ce_pix) {
            uint32_t colour = 0xFF000000 | top->VGA_B << 16 | top->VGA_G << 8 | top->VGA_R;
            video.Clock(top->VGA_HB, top->VGA_VB, top->VGA_HS, top->VGA_VS, colour);
        }

        if (clk_sys.IsRising()) main_time++;
        return 1;
    }

    top->final();
    delete top;
    exit(0);
    return 0;
}

static const char* opt_res1 =
    "../software/VideoBrain BIOS (1977)(VideoBrain Computer Company)(VideoBrain)(ROM)[uvres-1n-2129-7802].bin";
static const char* opt_res2 =
    "../software/VideoBrain BIOS (1977)(VideoBrain Computer Company)(VideoBrain)(ROM)[7802G0-RESN2-KOREA].bin";
static const char* opt_cart = nullptr;
static bool        opt_run  = false;
static int         opt_cart_type = 0;

static void usage(const char* a0) {
    fprintf(stderr,
"Graphical VideoBrain simulator\n"
"Usage: %s [options]\n"
"  --res1 FILE   RES1 ROM (ioctl index 0)\n"
"  --res2 FILE   RES2 ROM (ioctl index 1)\n"
"  --cart FILE   cartridge image (ioctl index 2)\n"
"  --run         start running immediately\n"
"  --cart-type N 0 standard, 1 Timeshare, 2 Money Minder\n", a0);
}

int main(int argc, char** argv, char** env) {

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto need = [&](const char* w) -> const char* {
            if (i + 1 >= argc) { fprintf(stderr, "error: %s needs a value\n", w); exit(1); }
            return argv[++i];
        };
        if      (a == "--help" || a == "-h") { usage(argv[0]); return 0; }
        else if (a == "--res1") opt_res1 = need("--res1");
        else if (a == "--res2") opt_res2 = need("--res2");
        else if (a == "--cart") opt_cart = need("--cart");
        else if (a == "--run")  opt_run = true;
        else if (a == "--cart-type") opt_cart_type = atoi(need("--cart-type"));
        else { fprintf(stderr, "error: unknown option %s\n", a.c_str()); usage(argv[0]); return 1; }
    }

    top = new Vtop();
    Verilated::commandArgs(argc, argv);

    Verilated::traceEverOn(true);
    top->trace(tfp, 1);
    if (Trace) tfp->open(Trace_File);

    bus.ioctl_addr = &top->ioctl_addr;
    bus.ioctl_index = &top->ioctl_index;
    bus.ioctl_wait = &top->ioctl_wait;
    bus.ioctl_download = &top->ioctl_download;
    bus.ioctl_upload = &top->ioctl_upload;
    bus.ioctl_wr = &top->ioctl_wr;
    bus.ioctl_dout = &top->ioctl_dout;
    bus.ioctl_din = &top->ioctl_din;
    input.ps2_key = &top->ps2_key;

    top->kbd_matrix = 0;   // active high, nothing pressed
    top->joy_fire = 0;
    top->cart_type = (uint8_t)opt_cart_type;
    top->reset = 1;

    input.Initialise();
    if (video.Initialise(windowTitle) == 1) return 1;

    // QueueDownload only logs failures into the debug pane, which is easy to
    // miss, so check the files up front.
    auto check = [](const char* p, const char* what) {
        if (FILE* f = fopen(p, "rb")) { fclose(f); return true; }
        fprintf(stderr, "error: cannot open %s '%s' (cwd must be verilator/)\n", what, p);
        return false;
    };
    if (!check(opt_res1, "RES1")) return 1;
    if (!check(opt_res2, "RES2")) return 1;
    bus.QueueDownload(opt_res1, 0, true);
    bus.QueueDownload(opt_res2, 1, false);
    if (opt_cart) {
        if (!check(opt_cart, "cart")) return 1;
        bus.QueueDownload(opt_cart, 2, false);
    }
    if (opt_run) run_enable = true;

    bool done = false;
    while (!done) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            ImGui_ImplSDL2_ProcessEvent(&event);
            if (event.type == SDL_QUIT) done = true;
        }

        video.StartFrame();
        input.Read();

        // Host keys to the 9x4 VideoBrain matrix, bit = col * 4 + row.
        // Layout from MAME vidbrain.cpp INPUT_PORTS_START.
        {
            static const struct { SDL_Scancode sc; int bit; } KEYMAP[] = {
                {SDL_SCANCODE_I,0},{SDL_SCANCODE_O,1},{SDL_SCANCODE_P,2},{SDL_SCANCODE_SEMICOLON,3},
                {SDL_SCANCODE_U,4},{SDL_SCANCODE_K,5},{SDL_SCANCODE_L,6},{SDL_SCANCODE_COMMA,7},
                {SDL_SCANCODE_Y,8},{SDL_SCANCODE_J,9},{SDL_SCANCODE_M,10},{SDL_SCANCODE_RSHIFT,11},
                {SDL_SCANCODE_LSHIFT,11},
                {SDL_SCANCODE_T,12},{SDL_SCANCODE_H,13},{SDL_SCANCODE_N,14},{SDL_SCANCODE_BACKSPACE,15},
                {SDL_SCANCODE_R,16},{SDL_SCANCODE_G,17},{SDL_SCANCODE_B,18},{SDL_SCANCODE_SPACE,19},
                {SDL_SCANCODE_E,20},{SDL_SCANCODE_F,21},{SDL_SCANCODE_V,22},{SDL_SCANCODE_F4,23},
                {SDL_SCANCODE_W,24},{SDL_SCANCODE_D,25},{SDL_SCANCODE_C,26},{SDL_SCANCODE_F3,27},
                {SDL_SCANCODE_Q,28},{SDL_SCANCODE_S,29},{SDL_SCANCODE_X,30},{SDL_SCANCODE_F2,31},
                {SDL_SCANCODE_A,32},{SDL_SCANCODE_Z,33},{SDL_SCANCODE_SLASH,34},{SDL_SCANCODE_F1,35},
            };
            uint64_t m = 0;
            if (!ImGui::GetIO().WantCaptureKeyboard) {
                const Uint8* ks = SDL_GetKeyboardState(NULL);
                for (const auto& k : KEYMAP) if (ks[k.sc]) m |= (uint64_t)1 << k.bit;
            }
            top->kbd_matrix = m;
        }

        ImGui::NewFrame();

        // ------------------------------------------------------------------
        ImGui::Begin(windowTitle_Control);
        ImGui::SetWindowPos(windowTitle_Control, ImVec2(0, 0), ImGuiCond_Once);
        ImGui::SetWindowSize(windowTitle_Control, ImVec2(500, 170), ImGuiCond_Once);
        if (ImGui::Button("Reset")) { resetSim(); }
        ImGui::SameLine();
        if (ImGui::Button("Release reset")) { top->reset = 0; }
        ImGui::SameLine();
        ImGui::Checkbox("Run", &run_enable);
        ImGui::SameLine();
        single_step = false;
        if (ImGui::Button("Step")) { single_step = true; }
        ImGui::SameLine();
        multi_step = false;
        if (ImGui::Button("Multi step")) { multi_step = true; }
        ImGui::SliderInt("Batch size", &batchSize, 1000, 1000000);
        ImGui::SliderInt("Multi step", &multi_step_amount, 8, 65536);
        ImGui::Text("main_time %llu  frame %d  sim FPS %.1f",
                    (unsigned long long)main_time, video.count_frame, video.stats_fps);
        {
            static const char* types[] = { "Standard", "Timeshare", "Money Minder" };
            if (ImGui::Combo("Cartridge type", &opt_cart_type, types, 3))
                top->cart_type = (uint8_t)opt_cart_type;
        }
        if (ImGui::Button("Load cartridge...")) {
            ImGuiFileDialog::Instance()->OpenDialog("ChooseFileDlgKey", "Cartridge",
                                                    ".bin,.*", "../software/");
        }
        ImGui::End();

        // ------------------------------------------------------------------
        ImGui::Begin("F8 / bus");
        ImGui::SetWindowPos("F8 / bus", ImVec2(0, 170), ImGuiCond_Once);
        ImGui::SetWindowSize("F8 / bus", ImVec2(500, 180), ImGuiCond_Once);
        ImGui::Text("PC0 %04X   PC1 %04X   DC0 %04X",
                    (unsigned)TOP(pc0), (unsigned)TOP(pc1), (unsigned)TOP(dc0));
        ImGui::Text("acc %02X  visar %02X  romc %02X  phase %X  ce %d",
                    (unsigned)CPU(acc), (unsigned)CPU(visar),
                    (unsigned)CORE(romc), (unsigned)CORE(phase), (int)CORE(cpu_ce));
        ImGui::Text("ext addr %04X  rd %d wr %d  req %d grant %d  rdata %02X",
                    (unsigned)CORE(ext_addr), (int)CORE(ext_rd), (int)CORE(ext_wr),
                    (int)CORE(ext_req), (int)CORE(ext_grant), (unsigned)CORE(ext_rdata));
        ImGui::Text("port A out %02X  port B out %02X",
                    (unsigned)TOP(po_a_n), (unsigned)TOP(po_b_n));
        ImGui::End();

        // ------------------------------------------------------------------
        ImGui::Begin("UV201");
        ImGui::SetWindowPos("UV201", ImVec2(0, 350), ImGuiCond_Once);
        ImGui::SetWindowSize("UV201", ImVec2(500, 330), ImGuiCond_Once);
        ImGui::Text("cmd %02X  bg %02X  fmod %02X  y_int %02X",
                    (unsigned)UVR(r_cmd), (unsigned)UVR(r_bg),
                    (unsigned)UVR(r_fmod), (unsigned)UVR(r_y_int));
        ImGui::Text("enb %d  x_zoom %d  y_zoom %d  list %s",
                    (int)TOP(video_en), (int)TOP(x_zoom), (int)TOP(y_zoom),
                    CORE(uv_o_a_b) ? "A" : "B");
        ImGui::Text("hpos %3d  vpos %3d  field %d  hblank %d  vblank %d",
                    (int)TOP(hpos), (int)TOP(vpos), (int)CORE(field_l),
                    (int)top->VGA_HB, (int)top->VGA_VB);
        ImGui::Separator();
        ImGui::Text("fetcher state %2d  obj %2d  bytes_left %2d  xdelta %3d",
                    (int)FET(state), (int)FET(entry_i),
                    (int)FET(bytes_left), (int)FET(xdelta_l));
        ImGui::Text("y_lo %02X  xy_hi %02X  dy %02X  dx %02X  x %02X  rp %04X",
                    (unsigned)FET(y_lo_l), (unsigned)FET(xy_hi_l), (unsigned)FET(dy_l),
                    (unsigned)FET(dx_l), (unsigned)FET(x_l), (unsigned)FET(ptr_l));
        ImGui::Text("FIFO level %d  valid %d  pop %d  umireq %d  dmareq %d",
                    (int)TOP(fifo_level), (int)TOP(fifo_valid), (int)CORE(fifo_pop_l),
                    (int)CORE(fetch_umireq), (int)CORE(dmareq0));
        ImGui::Separator();
        ImGui::Text("renderer: idx %02X  shift %d/%d  gap %d",
                    (unsigned)REN(idx_l), (int)REN(shift_active),
                    (int)REN(shift_cnt), (int)REN(gap_cnt));
        ImGui::End();

        // ------------------------------------------------------------------
        ImGui::Begin("RES1 $0000-$07FF");
        mem_edit.DrawContents(&BUS(res1_rom), 2048, 0x0000);
        ImGui::End();

        ImGui::Begin("RES2 $2000-$27FF");
        mem_edit.DrawContents(&BUS(res2_rom), 2048, 0x2000);
        ImGui::End();

        ImGui::Begin("Cartridge $1000-$1FFF");
        mem_edit.DrawContents(&BUS(cart_rom), 4096, 0x1000);
        ImGui::End();

        ImGui::Begin("System RAM $0C00-$0FFF");
        mem_edit.DrawContents(&BUS(sys_ram), 1024, 0x0C00);
        ImGui::End();

        // ------------------------------------------------------------------
        ImGui::Begin("Keyboard");
        ImGui::TextUnformatted(
            "Letters A-Z and , ; / type themselves.\n"
            "Digits are SHIFTED letters, and SHIFT is a lock: tap it, do not hold.\n"
            "  1=Z 2=X 3=C 4=S 5=D 6=F 7=W 8=E 9=R 0=/\n"
            "SPACE = RUN/STOP      BACKSPACE = ERASE/RESTART\n"
            "F1 = BACK/TEXT        F2 = PREVIOUS/COLOR\n"
            "F3 = NEXT/CLOCK       F4 = SPECIAL/ALARM");
        ImGui::Separator();
        ImGui::Text("matrix %09llX  latch %02X",
                    (unsigned long long)top->kbd_matrix, (unsigned)TOP(po_a_n) ^ 0xFF);
        ImGui::End();

        ImGui::Begin(windowTitle_Trace);
        ImGui::Checkbox("Write VCD", &Trace);
        ImGui::InputText("File", Trace_File, IM_ARRAYSIZE(Trace_File));
        ImGui::End();

        console.Draw(windowTitle_DebugLog, &showDebugLog, ImVec2(500, 200));

        // ------------------------------------------------------------------
        int windowX = 520;
        int windowWidth = (int)(video.output_width * VGA_SCALE_X) + 24;
        int windowHeight = (int)(video.output_height * VGA_SCALE_Y) + 90;

        ImGui::Begin(windowTitle_Video);
        ImGui::SetWindowPos(windowTitle_Video, ImVec2(windowX, 0), ImGuiCond_Once);
        ImGui::SetWindowSize(windowTitle_Video, ImVec2(windowWidth, windowHeight), ImGuiCond_Once);
        ImGui::SetNextItemWidth(300);
        ImGui::SliderFloat("Zoom", &vga_scale, 1, 8);
        ImGui::SameLine();
        ImGui::Checkbox("Flip V", &video.output_vflip);
        ImGui::Text("frame %d  %dx%d  sim FPS %.1f",
                    video.count_frame, video.output_width, video.output_height,
                    video.stats_fps);
        ImGui::Image(video.texture_id,
                     ImVec2(video.output_width * VGA_SCALE_X, video.output_height * VGA_SCALE_Y));
        ImGui::End();

        if (ImGuiFileDialog::Instance()->Display("ChooseFileDlgKey")) {
            if (ImGuiFileDialog::Instance()->IsOk()) {
                std::string f = ImGuiFileDialog::Instance()->GetFilePathName();
                fprintf(stderr, "[cart] %s -> ioctl index 2\n", f.c_str());
                bus.QueueDownload(f, 2, true);
            }
            ImGuiFileDialog::Instance()->Close();
        }

        video.UpdateTexture();

        // Hold reset until the images have finished downloading.
        if (!bus.HasQueue() && !*bus.ioctl_download) top->reset = 0;

        if (run_enable) {
            for (int step = 0; step < batchSize; step++) verilate();
        } else {
            if (single_step) verilate();
            if (multi_step) for (int step = 0; step < multi_step_amount; step++) verilate();
        }
    }

    video.CleanUp();
    input.CleanUp();
    return 0;
}
