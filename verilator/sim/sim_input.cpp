#include "sim_console.h"
#include "sim_input.h"

#include <string>
#include <stdlib.h>

#ifndef _MSC_VER
#include <SDL2/SDL.h>
extern bool headless; // defined in sim_main.cpp
int m_keyboardStateCount;
const Uint8* m_keyboardState;
Uint8* m_keyboardState_last = NULL;
#else
#define WIN32
#include <dinput.h>
//#define DIRECTINPUT_VERSION 0x0800
IDirectInput8* m_directInput;
IDirectInputDevice8* m_keyboard;
unsigned char m_keyboardState[256];
unsigned char m_keyboardState_last[256];
#endif

#include <vector>

static DebugConsole console;

#ifdef WIN32
static const unsigned int ev2ps2[] =
{
	PS2_NONE, //0   KEY_RESERVED
	0x76, //1   KEY_ESC
	0x16, //2   KEY_1
	0x1e, //3   KEY_2
	0x26, //4   KEY_3
	0x25, //5   KEY_4
	0x2e, //6   KEY_5
	0x36, //7   KEY_6
	0x3d, //8   KEY_7
	0x3e, //9   KEY_8
	0x46, //10  KEY_9
	0x45, //11  KEY_0
	0x4e, //12  KEY_MINUS
	0x55, //13  KEY_EQUAL
	0x66, //14  KEY_BACKSPACE
	0x0d, //15  KEY_TAB
	0x15, //16  KEY_Q
	0x1d, //17  KEY_W
	0x24, //18  KEY_E
	0x2d, //19  KEY_R
	0x2c, //20  KEY_T
	0x35, //21  KEY_Y
	0x3c, //22  KEY_U
	0x43, //23  KEY_I
	0x44, //24  KEY_O
	0x4d, //25  KEY_P
	0x54, //26  KEY_LEFTBRACE
	0x5b, //27  KEY_RIGHTBRACE
	0x5a, //28  KEY_ENTER
	 0x14, //29  KEY_LEFTCTRL
	0x1c, //30  KEY_A
	0x1b, //31  KEY_S
	0x23, //32  KEY_D
	0x2b, //33  KEY_F
	0x34, //34  KEY_G
	0x33, //35  KEY_H
	0x3b, //36  KEY_J
	0x42, //37  KEY_K
	0x4b, //38  KEY_L
	0x4c, //39  KEY_SEMICOLON
	0x52, //40  KEY_APOSTROPHE
	0x0e, //41  KEY_GRAVE
	 0x12, //42  KEY_LEFTSHIFT
	0x5d, //43  KEY_BACKSLASH
	0x1a, //44  KEY_Z
	0x22, //45  KEY_X
	0x21, //46  KEY_C
	0x2a, //47  KEY_V
	0x32, //48  KEY_B
	0x31, //49  KEY_N
	0x3a, //50  KEY_M
	0x41, //51  KEY_COMMA
	0x49, //52  KEY_DOT
	0x4a, //53  KEY_SLASH
	 0x59, //54  KEY_RIGHTSHIFT
	0x7c, //55  KEY_KPASTERISK
	 0x11, //56  KEY_LEFTALT
	0x29, //57  KEY_SPACE
	0x58, //58  KEY_CAPSLOCK
	0x05, //59  KEY_F1
	0x06, //60  KEY_F2
	0x04, //61  KEY_F3
	0x0c, //62  KEY_F4
	0x03, //63  KEY_F5
	0x0b, //64  KEY_F6
	0x83, //65  KEY_F7
	0x0a, //66  KEY_F8
	0x01, //67  KEY_F9
	0x09, //68  KEY_F10
	EMU_SWITCH_2 | 0x77, //69  KEY_NUMLOCK
	EMU_SWITCH_1 | 0x7E, //70  KEY_SCROLLLOCK
	0x6c, //71  KEY_KP7
	0x75, //72  KEY_KP8
	0x7d, //73  KEY_KP9
	0x7b, //74  KEY_KPMINUS
	0x6b, //75  KEY_KP4
	0x73, //76  KEY_KP5
	0x74, //77  KEY_KP6
	0x79, //78  KEY_KPPLUS
	0x69, //79  KEY_KP1
	0x72, //80  KEY_KP2
	0x7a, //81  KEY_KP3
	0x70, //82  KEY_KP0
	0x71, //83  KEY_KPDOT
	PS2_NONE, //84  ???
	PS2_NONE, //85  KEY_ZENKAKU
	0x61, //86  KEY_102ND
	0x78, //87  KEY_F11
	0x07, //88  KEY_F12
	PS2_NONE, //89  KEY_RO
	PS2_NONE, //90  KEY_KATAKANA
	PS2_NONE, //91  KEY_HIRAGANA
	PS2_NONE, //92  KEY_HENKAN
	PS2_NONE, //93  KEY_KATAKANA
	PS2_NONE, //94  KEY_MUHENKAN
	PS2_NONE, //95  KEY_KPJPCOMMA
	EXT | 0x5a, //96  KEY_KPENTER
	 EXT | 0x14, //97  KEY_RIGHTCTRL
	EXT | 0x4a, //98  KEY_KPSLASH
	0xE2, //99  KEY_SYSRQ
	 EXT | 0x11, //100 KEY_RIGHTALT
	PS2_NONE, //101 KEY_LINEFEED
	EXT | 0x6c, //102 KEY_HOME
	EXT | 0x75, //103 KEY_UP
	EXT | 0x7d, //104 KEY_PAGEUP
	EXT | 0x6b, //105 KEY_LEFT
	EXT | 0x74, //106 KEY_RIGHT
	EXT | 0x69, //107 KEY_END
	EXT | 0x72, //108 KEY_DOWN
	EXT | 0x7a, //109 KEY_PAGEDOWN
	EXT | 0x70, //110 KEY_INSERT
	EXT | 0x71, //111 KEY_DELETE
	PS2_NONE, //112 KEY_MACRO
	PS2_NONE, //113 KEY_MUTE
	PS2_NONE, //114 KEY_VOLUMEDOWN
	PS2_NONE, //115 KEY_VOLUMEUP
	PS2_NONE, //116 KEY_POWER
	PS2_NONE, //117 KEY_KPEQUAL
	PS2_NONE, //118 KEY_KPPLUSMINUS
	0xE1, //119 KEY_PAUSE
	PS2_NONE, //120 KEY_SCALE
	PS2_NONE, //121 KEY_KPCOMMA
	PS2_NONE, //122 KEY_HANGEUL
	PS2_NONE, //123 KEY_HANJA
	PS2_NONE, //124 KEY_YEN
	 EXT | 0x1f, //125 KEY_LEFTMETA
	 EXT | 0x27, //126 KEY_RIGHTMETA
	PS2_NONE, //127 KEY_COMPOSE
	PS2_NONE, //128 KEY_STOP
	PS2_NONE, //129 KEY_AGAIN
	PS2_NONE, //130 KEY_PROPS
	PS2_NONE, //131 KEY_UNDO
	PS2_NONE, //132 KEY_FRONT
	PS2_NONE, //133 KEY_COPY
	PS2_NONE, //134 KEY_OPEN
	PS2_NONE, //135 KEY_PASTE
	PS2_NONE, //136 KEY_FIND
	PS2_NONE, //137 KEY_CUT
	PS2_NONE, //138 KEY_HELP
	PS2_NONE, //139 KEY_MENU
	PS2_NONE, //140 KEY_CALC
	PS2_NONE, //141 KEY_SETUP
	PS2_NONE, //142 KEY_SLEEP
	PS2_NONE, //143 KEY_WAKEUP
	PS2_NONE, //144 KEY_FILE
	PS2_NONE, //145 KEY_SENDFILE
	PS2_NONE, //146 KEY_DELETEFILE
	PS2_NONE, //147 KEY_XFER
	PS2_NONE, //148 KEY_PROG1
	PS2_NONE, //149 KEY_PROG2
	PS2_NONE, //150 KEY_WWW
	PS2_NONE, //151 KEY_MSDOS
	PS2_NONE, //152 KEY_SCREENLOCK
	PS2_NONE, //153 KEY_DIRECTION
	PS2_NONE, //154 KEY_CYCLEWINDOWS
	PS2_NONE, //155 KEY_MAIL
	PS2_NONE, //156 KEY_BOOKMARKS
	PS2_NONE, //157 KEY_COMPUTER
	PS2_NONE, //158 KEY_BACK
	PS2_NONE, //159 KEY_FORWARD
	PS2_NONE, //160 KEY_CLOSECD
	PS2_NONE, //161 KEY_EJECTCD
	PS2_NONE, //162 KEY_EJECTCLOSECD
	PS2_NONE, //163 KEY_NEXTSONG
	PS2_NONE, //164 KEY_PLAYPAUSE
	PS2_NONE, //165 KEY_PREVIOUSSONG
	PS2_NONE, //166 KEY_STOPCD
	PS2_NONE, //167 KEY_RECORD
	PS2_NONE, //168 KEY_REWIND
	PS2_NONE, //169 KEY_PHONE
	PS2_NONE, //170 KEY_ISO
	PS2_NONE, //171 KEY_CONFIG
	PS2_NONE, //172 KEY_HOMEPAGE
	PS2_NONE, //173 KEY_REFRESH
	PS2_NONE, //174 KEY_EXIT
	PS2_NONE, //175 KEY_MOVE
	PS2_NONE, //176 KEY_EDIT
	PS2_NONE, //177 KEY_SCROLLUP
	PS2_NONE, //178 KEY_SCROLLDOWN
	PS2_NONE, //179 KEY_KPLEFTPAREN
	PS2_NONE, //180 KEY_KPRIGHTPAREN
	PS2_NONE, //181 KEY_NEW
	PS2_NONE, //182 KEY_REDO
	PS2_NONE, //183 KEY_F13
	PS2_NONE, //184 KEY_F14
	PS2_NONE, //185 KEY_F15
	PS2_NONE, //186 KEY_F16
	EMU_SWITCH_1 | 1, //187 KEY_F17
	EMU_SWITCH_1 | 2, //188 KEY_F18
	EMU_SWITCH_1 | 3, //189 KEY_F19
	EMU_SWITCH_1 | 4, //190 KEY_F20
	PS2_NONE, //191 KEY_F21
	PS2_NONE, //192 KEY_F22
	PS2_NONE, //193 KEY_F23
	0x5D, //194 U-mlaut on DE mapped to backslash
	PS2_NONE, //195 ???
	PS2_NONE, //196 ???
	PS2_NONE, //197 ???
	PS2_NONE, //198 ???
	PS2_NONE, //199 ???
	EXT | 0x75, //200 KEY_UP
	PS2_NONE, //201 ???
	PS2_NONE, //202 ???
	EXT | 0x6b, //203 KEY_LEFT
	PS2_NONE, //204 ???
	EXT | 0x74, //205 KEY_RIGHT
	PS2_NONE, //206 ???
	PS2_NONE, //207 ???
	EXT | 0x72, //208 KEY_DOWN
	PS2_NONE, //209 ???
	PS2_NONE, //210 ???
	PS2_NONE, //211 ???
	PS2_NONE, //212 ???
	PS2_NONE, //213 ???
	PS2_NONE, //214 ???
	PS2_NONE, //215 ???
	PS2_NONE, //216 ???
	PS2_NONE, //217 ???
	PS2_NONE, //218 ???
	PS2_NONE, //219 ???
	PS2_NONE, //220 ???
	PS2_NONE, //221 ???
	PS2_NONE, //222 ???
	PS2_NONE, //223 ???
	PS2_NONE, //224 ???
	PS2_NONE, //225 ???
	PS2_NONE, //226 ???
	PS2_NONE, //227 ???
	PS2_NONE, //228 ???
	PS2_NONE, //229 ???
	PS2_NONE, //230 ???
	PS2_NONE, //231 ???
	PS2_NONE, //232 ???
	PS2_NONE, //233 ???
	PS2_NONE, //234 ???
	PS2_NONE, //235 ???
	PS2_NONE, //236 ???
	PS2_NONE, //237 ???
	PS2_NONE, //238 ???
	PS2_NONE, //239 ???
	PS2_NONE, //240 ???
	PS2_NONE, //241 ???
	PS2_NONE, //242 ???
	PS2_NONE, //243 ???
	PS2_NONE, //244 ???
	PS2_NONE, //245 ???
	PS2_NONE, //246 ???
	PS2_NONE, //247 ???
	PS2_NONE, //248 ???
	PS2_NONE, //249 ???
	PS2_NONE, //250 ???
	PS2_NONE, //251 ???
	PS2_NONE, //252 ???
	PS2_NONE, //253 ???
	PS2_NONE, //254 ???
	PS2_NONE  //255 ???
};
#else
static const int ev2ps2[] =
{
	PS2_NONE, //0   KEY_RESERVED
	PS2_NONE, //1   KEY_RESERVED
	PS2_NONE, //2   KEY_RESERVED
	PS2_NONE, //3   KEY_RESERVED
	0x1c, //4  KEY_A
	0x32, //5  KEY_B
	0x21, //6  KEY_C
	0x23, //7  KEY_D
	0x24, //8  KEY_E
	0x2b, //9  KEY_F
	0x34, //10  KEY_G
	0x33, //11  KEY_H
	0x43, //12  KEY_I
	0x3b, //13  KEY_J
	0x42, //14  KEY_K
	0x4b, //15  KEY_L
	0x3a, //16  KEY_M
	0x31, //17  KEY_N
	0x44, //18  KEY_O
	0x4d, //19  KEY_P
	0x15, //20  KEY_Q
	0x2d, //21  KEY_R
	0x1b, //22  KEY_S
	0x2c, //23  KEY_T
	0x3c, //24  KEY_U
	0x2a, //25  KEY_V
	0x1d, //26  KEY_W
	0x22, //27  KEY_X
	0x35, //28  KEY_Y
	0x1a, //29  KEY_Z
	0x16, //30   KEY_1
	0x1e, //31   KEY_2
	0x26, //32  KEY_3
	0x25, //33  KEY_4
	0x2e, //34  KEY_5
	0x36, //35  KEY_6
	0x3d, //36  KEY_7
	0x3e, //37  KEY_8
	0x46, //38  KEY_9
	0x45, //39  KEY_0
	0x5a, //40  KEY_ENTER
	0x76, //41  KEY_ESC
	0x66, //42  KEY_BACKSPACE
	0x0d, //43  KEY_TAB
	0x29, //44  KEY_SPACE
	0x4e, //45  KEY_MINUS
	0x55, //46  KEY_EQUAL
	0x54, //47  KEY_LEFTBRACE
	0x5b, //48  KEY_RIGHTBRACE
	0x5d, //49  KEY_BACKSLASH
	PS2_NONE, //50  KEY_RESERVED
	0x4c, //51  KEY_SEMICOLON
	0x52, //52  KEY_APOSTROPHE
	0x0e, //53  KEY_GRAVE
	0x41, //54  KEY_COMMA
	0x49, //55  KEY_DOT
	0x4a, //56  KEY_SLASH
	0x58, //57  KEY_CAPSLOCK
	0x05, //58  KEY_F1
	0x06, //59  KEY_F2
	0x04, //60  KEY_F3
	0x0c, //61  KEY_F4
	0x03, //62  KEY_F5
	0x0b, //63  KEY_F6
	0x83, //64  KEY_F7
	0x0a, //65  KEY_F8
	0x01, //66  KEY_F9
	0x09, //67  KEY_F10
	0x78, //68  KEY_F11
	0x07, //69  KEY_F12
	PS2_NONE, //70  KEY_PRINT
	EMU_SWITCH_1 | 0x7E, //71  KEY_SCROLLLOCK
	0xE1, //72 KEY_PAUSE
	EXT | 0x70, //73  KEY_INSERT
	EXT | 0x6c, //74  KEY_HOME
	EXT | 0x7d, //75  KEY_PAGEUP
	EXT | 0x71, //76  KEY_DELETE
	EXT | 0x69, //77  KEY_END
	EXT | 0x7a, //78  KEY_PAGEDOWN
	EXT | 0x74, //79  KEY_RIGHT
	EXT | 0x6b, //80  KEY_LEFT
	EXT | 0x72, //81  KEY_DOWN
	EXT | 0x75, //82  KEY_UP
	0x77, //83  SDL_SCANCODE_NUMLOCKCLEAR  (Mac keypad Clear -> ADB 0x47 via adb.v)
	EXT | 0x4a, //84  KEY_KPSLASH
	0x7c, //85  KEY_KPASTERISK
	0x7b, //86  KEY_KPMINUS
	0x79, //87  KEY_KPPLUS
	EXT | 0x5a, //88  KEY_KPENTER
	0x69, //89  KEY_KP1
	0x72, //90  KEY_KP2
	0x7a, //91  KEY_KP3
	0x6b, //92  KEY_KP4
	0x73, //93  KEY_KP5
	0x74, //94  KEY_KP6
	0x6c, //95  KEY_KP7
	0x75, //96  KEY_KP8
	0x7d, //97  KEY_KP9
	0x70, //98  KEY_KP0
	0x71, //99  KEY_KPDOT
	0x61, //100 SDL_SCANCODE_NONUSBACKSLASH  (102nd key / ISO <> between LShift and Z)
	EXT | 0x27, //101 SDL_SCANCODE_APPLICATION  (reuse PS/2 R-Windows code -> Option/Closed Apple)
	PS2_NONE, //102 KEY_POWER
	0x0F, //103 SDL_SCANCODE_KP_EQUALS  (numeric keypad =)
	PS2_NONE, //104 KEY_F13
	PS2_NONE, //105 KEY_F14
	PS2_NONE, //106 KEY_F15
	PS2_NONE, //107 KEY_F16
	EMU_SWITCH_1 | 1, //108 KEY_F17
	EMU_SWITCH_1 | 2, //109 KEY_F18
	EMU_SWITCH_1 | 3, //110 KEY_F19
	EMU_SWITCH_1 | 4, //111 KEY_F20
	PS2_NONE, //112 KEY_F21
	PS2_NONE, //113 KEY_F22
	PS2_NONE, //114 KEY_F23
	PS2_NONE, //115 KEY_F24
	PS2_NONE, //116 
	PS2_NONE, //117 KEY_HELP
	PS2_NONE, //118 
	PS2_NONE, //119 
	PS2_NONE, //120 
	PS2_NONE, //121 
	PS2_NONE, //122 
	PS2_NONE, //123 
	PS2_NONE, //124 
	PS2_NONE, //125 
	PS2_NONE, //126 
	PS2_NONE, //127 
	PS2_NONE, //128 
	PS2_NONE, //129 
	PS2_NONE, //130 
	PS2_NONE, //131 
	PS2_NONE, //132 
	PS2_NONE, //133 
	PS2_NONE, //134 
	PS2_NONE, //135 
	PS2_NONE, //136 
	PS2_NONE, //137 
	PS2_NONE, //138 
	PS2_NONE, //139 
	PS2_NONE, //140 
	PS2_NONE, //141 
	PS2_NONE, //142 
	PS2_NONE, //143 
	PS2_NONE, //144 
	PS2_NONE, //145 
	PS2_NONE, //146 
	PS2_NONE, //147 
	PS2_NONE, //148 
	PS2_NONE, //149 
	PS2_NONE, //150 
	PS2_NONE, //151 
	PS2_NONE, //152 
	PS2_NONE, //153 
	PS2_NONE, //154 
	PS2_NONE, //155 
	PS2_NONE, //156 
	PS2_NONE, //157 
	PS2_NONE, //158 
	PS2_NONE, //159 
	PS2_NONE, //160 
	PS2_NONE, //161 
	PS2_NONE, //162 
	PS2_NONE, //163 
	PS2_NONE, //164 
	PS2_NONE, //165 
	PS2_NONE, //166 
	PS2_NONE, //167 
	PS2_NONE, //168 
	PS2_NONE, //169 
	PS2_NONE, //170 
	PS2_NONE, //171 
	PS2_NONE, //172 
	PS2_NONE, //173 
	PS2_NONE, //174 
	PS2_NONE, //175 
	PS2_NONE, //176 
	PS2_NONE, //177 
	PS2_NONE, //178 
	PS2_NONE, //179 
	PS2_NONE, //180 
	PS2_NONE, //181 
	PS2_NONE, //182 
	PS2_NONE, //183 
	PS2_NONE, //184 
	PS2_NONE, //185 
	PS2_NONE, //186 
	PS2_NONE, //187 
	PS2_NONE, //188 
	PS2_NONE, //189 
	PS2_NONE, //180 
	PS2_NONE, //191 
	PS2_NONE, //192 
	PS2_NONE, //193 
	PS2_NONE, //194 
	PS2_NONE, //195 
	PS2_NONE, //196 
	PS2_NONE, //197 
	PS2_NONE, //198 
	PS2_NONE, //109 
	PS2_NONE, //200 
	PS2_NONE, //201 
	PS2_NONE, //202 
	PS2_NONE, //203 
	PS2_NONE, //204 
	PS2_NONE, //205 
	PS2_NONE, //206 
	PS2_NONE, //207 
	PS2_NONE, //208 
	PS2_NONE, //209 
	PS2_NONE, //210 
	PS2_NONE, //211 
	PS2_NONE, //212 
	PS2_NONE, //213 
	PS2_NONE, //214 
	PS2_NONE, //215 
	PS2_NONE, //216 
	PS2_NONE, //217 
	PS2_NONE, //218 
	PS2_NONE, //219 
	PS2_NONE, //220 
	PS2_NONE, //221 
	PS2_NONE, //222 
	PS2_NONE, //223 
	 0x14, //224  SDL_SCANCODE_LCTRL
	 0x12, //225  SDL_SCANCODE_LSHIFT
	 0x11, //226  SDL_SCANCODE_LALT  (Open Apple / Command)
	 EXT | 0x1F, //227  SDL_SCANCODE_LGUI  (Mac ⌘, Win key) -> Closed Apple / Option
	 EXT | 0x14, //228  SDL_SCANCODE_RCTRL
	 0x59, //229  SDL_SCANCODE_RSHIFT
	 EXT | 0x11, //230  SDL_SCANCODE_RALT
	 EXT | 0x27, //231  SDL_SCANCODE_RGUI  (RightGUI) -> Closed Apple / Option (menu key PS/2 code)

};
/* http://www-personal.umich.edu/~bazald/l/api/_s_d_l__scancode_8h.html */
#endif
bool ReadKeyboard()
{
#ifdef WIN32
	HRESULT result;

	// Read the keyboard device.
	result = m_keyboard->GetDeviceState(sizeof(m_keyboardState), (LPVOID)&m_keyboardState);
	if (FAILED(result))
	{
		// If the keyboard lost focus or was not acquired then try to get control back.
		if ((result == DIERR_INPUTLOST) || (result == DIERR_NOTACQUIRED)) { m_keyboard->Acquire(); }
		else { return false; }
	}
#else
	if (headless) {
		m_keyboardStateCount = 0;
		m_keyboardState = nullptr;
		return true;
	}
	m_keyboardState = SDL_GetKeyboardState(&m_keyboardStateCount);
	if (!m_keyboardState_last) m_keyboardState_last = (Uint8*)calloc(m_keyboardStateCount, sizeof(Uint8));
	////fprintf(stderr,"count: %d\n",m_keyboardStateCount);
#endif

	return true;
}

int SimInput::Initialise() {

#ifdef WIN32
	m_directInput = 0;
	m_keyboard = 0;
	HRESULT result;
	// Initialize the main direct input interface.
	result = DirectInput8Create(GetModuleHandle(nullptr), DIRECTINPUT_VERSION, IID_IDirectInput8, (void**)&m_directInput, NULL);
	if (FAILED(result)) { return false; }
	// Initialize the direct input interface for the keyboard.
	result = m_directInput->CreateDevice(GUID_SysKeyboard, &m_keyboard, NULL);
	if (FAILED(result)) { return false; }
	// Set the data format.  In this case since it is a keyboard we can use the predefined data format.
	result = m_keyboard->SetDataFormat(&c_dfDIKeyboard);
	if (FAILED(result)) { return false; }
	// Now acquire the keyboard.
	result = m_keyboard->Acquire();
	if (FAILED(result)) { return false; }
#endif
	return 0;
}

void SimInput::Read() {
	// Read keyboard state
	bool pr = ReadKeyboard();

	// Collect inputs
	for (int i = 0; i < inputCount; i++) {
#ifdef WIN32
		inputs[i] = m_keyboardState[mappings[i]] & 0x80;
#else
		inputs[i] = headless ? 0 : m_keyboardState[mappings[i]];
#endif
	}

#ifdef WIN32
	for (unsigned char k = 0; k < 220; k++) {

		if (m_keyboardState_last[k] != m_keyboardState[k]) {
			unsigned int ext = ev2ps2[k] & EXT;
			//fprintf(stderr, "ev2ps2[k] = %x  ext = %x  temp = %x\n", ev2ps2[k], ext, EXT | 0x6b);
			SimInput_PS2KeyEvent evt = SimInput_PS2KeyEvent(k, m_keyboardState[k], ext, ev2ps2[k]);
			keyEvents.push(evt);
		}
		m_keyboardState_last[k] = m_keyboardState[k];
	}
#else
	if (!headless) {
		// Caps Lock: macOS SDL delivers the latch as a transient scancode
		// blip that polling typically misses, but SDL_GetModState() &
		// KMOD_CAPS reflects latch transitions reliably. Synthesize one
		// PS/2 key-down activation per toggle; adb.v owns the IIgs latch
		// state and ignores the matching physical key-up edge.
		static int caps_mod_last = -1;
		int caps_mod_now = (SDL_GetModState() & KMOD_CAPS) ? 1 : 0;
		if (caps_mod_last == -1) caps_mod_last = caps_mod_now;
		if (caps_mod_last != caps_mod_now) {
			const unsigned int CAPSLOCK_PS2 = 0x58;
			SimInput_PS2KeyEvent evt(57, true, false, CAPSLOCK_PS2);
			keyEvents.push(evt);
			caps_mod_last = caps_mod_now;
			if (m_keyboardState_last && m_keyboardStateCount > 57) {
				m_keyboardState_last[57] = caps_mod_now;
			}
		}
		for (int k = 0; k < m_keyboardStateCount; k++) {
			if (m_keyboardState_last[k] != m_keyboardState[k]) {
				if (k == 57) {
					// Caps Lock handled via SDL_GetModState above.
					m_keyboardState_last[k] = m_keyboardState[k];
					continue;
				}
				unsigned int mapped = ev2ps2[k];
				bool ext = (mapped & EXT) != 0;
				SimInput_PS2KeyEvent evt = SimInput_PS2KeyEvent(k, m_keyboardState[k], ext, mapped);
				keyEvents.push(evt);
			}
			m_keyboardState_last[k] = m_keyboardState[k];
		}
	}
#endif

}

void SimInput::SetMapping(int index, int code) {
	//printf("index %d code %d\n", index, code);
	if (code < 256)
		mappings[index] = code;
	else
		mappings[index] = 0;
}

void SimInput::CleanUp() {

#ifdef WIN32
	// Release keyboard
	if (m_keyboard) { m_keyboard->Unacquire(); m_keyboard->Release(); m_keyboard = 0; }
	// Release direct input
	if (m_directInput) { m_directInput->Release(); m_directInput = 0; }
#endif
}

unsigned int ps2_key_temp;
bool ps2_clock = 1;


void SimInput::BeforeEval()
{
	if (keyEventTimer == 0) {

		if (keyEvents.size() > 0) {
			// Get chunk from queue
			SimInput_PS2KeyEvent evt = keyEvents.front();
			keyEvents.pop();

			//ps2_key_temp = ev2ps2[evt.code];
			ps2_key_temp = evt.mapped;
			/*fprintf(stderr, "PS2 KEY: code=%02x pressed=%d ext=%d mapped=%02x\n", evt.code, evt.pressed, evt.extended, evt.mapped);*/

			if (evt.extended) { ps2_key_temp |= (1UL << 8); }
			if (evt.pressed) { ps2_key_temp |= (1UL << 9); }
			if (ps2_clock) { ps2_key_temp |= (1UL << 10); }

			ps2_clock = !ps2_clock;

			*ps2_key = ps2_key_temp;

			keyEventTimer = keyEventWait;
		}
	}
	else {
		keyEventTimer--;
	}
}

SimInput::SimInput(int count, DebugConsole c)
{
	inputCount = count;
	console = c;
}

SimInput::~SimInput()
{

}
