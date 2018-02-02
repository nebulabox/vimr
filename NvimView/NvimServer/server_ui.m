/**
 * Tae Won Ha - http://taewon.de - @hataewon
 * See LICENSE
 */

#import <Foundation/Foundation.h>

#import "Logging.h"
#import "server_globals.h"
#import "NvimServer.h"
#import "CocoaCategories.h"
#import "DataWrapper.h"
#import "SharedTypes.h"

// FileInfo and Boolean are #defined by Carbon and NeoVim:
// Since we don't need the Carbon versions of them, we rename
// them.
#define FileInfo CarbonFileInfo
#define Boolean CarbonBoolean

#import <nvim/vim.h>
#import <nvim/api/vim.h>
#import <nvim/ui.h>
#import <nvim/ui_bridge.h>
#import <nvim/ex_getln.h>
#import <nvim/fileio.h>
#import <nvim/undo.h>
#import <nvim/mouse.h>
#import <nvim/screen.h>
#import <nvim/edit.h>
#import <nvim/syntax.h>
#import <nvim/aucmd.h>


#define pun_type(t, x) (*((t *) (&(x))))


static NSInteger _default_foreground = 0xFF000000;
static NSInteger _default_background = 0xFFFFFFFF;
static NSInteger _default_special = 0xFFFF0000;

typedef struct {
    UIBridgeData *bridge;
    Loop *loop;

    bool stop;
} ServerUiData;

// We declare nvim_main because it's not declared in any header files of neovim
extern int nvim_main(int argc, char **argv);


// The thread in which neovim's main runs
static uv_thread_t _nvim_thread;

// Condition variable used by the XPC's init to wait till our custom UI initialization
// is finished inside neovim
static bool _is_ui_launched = false;
static uv_mutex_t _mutex;
static uv_cond_t _condition;

static ServerUiData *_server_ui_data;

static NSString *_marked_text = nil;

static NSInteger _marked_row = 0;
static NSInteger _marked_column = 0;

// for 하 -> hanja popup, Cocoa first inserts 하, then sets marked text,
// cf docs/notes-on-cocoa-text-input.md
static NSInteger _marked_delta = 0;

static NSInteger _put_row = -1;
static NSInteger _put_column = -1;

static NSString *_backspace = nil;

static bool _dirty = false;

static NSInteger _initialWidth = 30;
static NSInteger _initialHeight = 15;

static NSMutableArray <NSData *> *_render_data;

#pragma mark Helper functions
static inline String vim_string_from(NSString *str) {
  return (String) { .data = (char *) str.cstr, .size = str.clength };
}

static void refresh_ui_screen(int type) {
  update_screen(type);
  setcursor();
  ui_flush();
}

static bool has_dirty_docs() {
  FOR_ALL_BUFFERS(buffer) {
    if (bufIsChanged(buffer)) {
      return true;
    }
  }

  return false;
}

static void send_dirty_status() {
  bool new_dirty_status = has_dirty_docs();
  DLOG("dirty status: %d vs. %d", _dirty, new_dirty_status);
  if (_dirty == new_dirty_status) {
    return;
  }

  _dirty = new_dirty_status;
  DLOG("sending dirty status: %d", _dirty);
  NSData *data = [[NSData alloc] initWithBytes:&_dirty length:sizeof(bool)];
  [_neovim_server sendMessageWithId:NvimServerMsgIdDirtyStatusChanged data:data];
  [data release];
}

static void send_cwd() {
  char_u *temp = xmalloc(MAXPATHL);
  if (os_dirname(temp, MAXPATHL) == FAIL) {
    xfree(temp);
    [_neovim_server sendMessageWithId:NvimServerMsgIdCwdChanged];
  }

  NSString *pwd = [NSString stringWithCString:(const char *) temp encoding:NSUTF8StringEncoding];
  xfree(temp);

  NSData *resultData = [pwd dataUsingEncoding:NSUTF8StringEncoding];
  [_neovim_server sendMessageWithId:NvimServerMsgIdCwdChanged data:resultData];
}

static HlAttrs HlAttrsFromAttrCode(int attr_code) {
  HlAttrs *aep = syn_cterm_attr2entry(attr_code);
  HlAttrs rgb_attrs = *aep;
  return rgb_attrs;
}

static void add_to_render_data(RenderDataType type, NSData *data) {
  NSMutableData *rData = [NSMutableData new];

  [rData appendBytes:&type length:sizeof(RenderDataType)];
  [rData appendData:data];

  [_render_data addObject:rData];
  [rData release];
}

static int foreground_for(HlAttrs attrs) {
  int mask  = attrs.rgb_ae_attr;
  return mask & HL_INVERSE ? attrs.rgb_bg_color: attrs.rgb_fg_color;
}

static int background_for(HlAttrs attrs) {
  int mask  = attrs.rgb_ae_attr;
  return mask & HL_INVERSE ? attrs.rgb_fg_color: attrs.rgb_bg_color;
}

static void send_colorscheme() {
  // It seems that the highlight groupt only gets updated when the screen is redrawn.
  // Since there's a guard var, probably it's safe to call it here...
  if (need_highlight_changed) {
    highlight_changed();
  }

  HlAttrs visualAttrs = HlAttrsFromAttrCode(highlight_attr[HLF_V]);
  HlAttrs dirAttrs = HlAttrsFromAttrCode(highlight_attr[HLF_D]);

  NSInteger values[] = {
      normal_fg, normal_bg,
      foreground_for(visualAttrs), background_for(visualAttrs),
      foreground_for(dirAttrs),
  };
  NSData *resultData = [NSData dataWithBytes:values length:5 * sizeof(NSInteger)];

  [_neovim_server sendMessageWithId:NvimServerMsgIdColorSchemeChanged data:resultData];
}

static void insert_marked_text(NSString *markedText) {
  _marked_text = [markedText retain]; // release when the final text is input in -vimInput

  nvim_input(vim_string_from(markedText));
}

static void delete_marked_text() {
  NSUInteger length = [_marked_text lengthOfBytesUsingEncoding:NSUTF32StringEncoding] / 4;

  [_marked_text release];
  _marked_text = nil;

  for (int i = 0; i < length; i++) {
    nvim_input(vim_string_from(_backspace));
  }
}

static void run_neovim(void *arg) {
  int argc = 1;
  char **argv;

  @autoreleasepool {
    NSArray<NSString *> *nvimArgs = (NSArray *) arg;

    argc = (int) nvimArgs.count + 1;
    argv = (char **) malloc((argc + 1) * sizeof(char *));

    argv[0] = "nvim";
    for (int i = 0; i < nvimArgs.count; i++) {
      argv[i + 1] = (char *) nvimArgs[(NSUInteger) i].cstr;
    }

    [nvimArgs release]; // retained in start_neovim()
  }

  nvim_main(argc, argv);

  free(argv);
}

static void set_ui_size(UIBridgeData *bridge, int width, int height) {
  bridge->ui->width = width;
  bridge->ui->height = height;
  bridge->bridge.width = width;
  bridge->bridge.height = height;
}

static void server_ui_scheduler(Event event, void *d) {
  UI *ui = d;
  ServerUiData *data = ui->data;
  loop_schedule(data->loop, event);
}

static void server_ui_main(UIBridgeData *bridge, UI *ui) {
  _render_data = [NSMutableArray new];

  Loop loop;
  loop_init(&loop, NULL);

  _server_ui_data = xcalloc(1, sizeof(ServerUiData));
  ui->data = _server_ui_data;
  _server_ui_data->bridge = bridge;
  _server_ui_data->loop = &loop;

  set_ui_size(bridge, (int) _initialWidth, (int) _initialHeight);

  _server_ui_data->stop = false;
  CONTINUE(bridge);

  uv_mutex_lock(&_mutex);
  _is_ui_launched = true;
  uv_cond_signal(&_condition);
  uv_mutex_unlock(&_mutex);

  while (!_server_ui_data->stop) {
    loop_poll_events(&loop, -1);
  }

  ui_bridge_stopped(bridge);
  loop_close(&loop, false);

  xfree(_server_ui_data);
  xfree(ui);

  [_render_data release];
}

#pragma mark NeoVim's UI callbacks

static void server_ui_flush(UI *ui __unused) {
  @autoreleasepool {
    if (_render_data.count == 0) {
      return;
    }

    [_neovim_server sendMessageWithId:NvimServerMsgIdFlush
                                 data:[NSKeyedArchiver archivedDataWithRootObject:_render_data]];
    [_render_data removeAllObjects];
  }
}

static void server_ui_resize(UI *ui __unused, Integer width, Integer height) {
  @autoreleasepool {
    server_ui_flush(NULL);

    NSInteger values[] = {width, height};
    NSData *data = [[NSData alloc] initWithBytes:values length:(2 * sizeof(NSInteger))];
    [_neovim_server sendMessageWithId:NvimServerMsgIdResize data:data];
    [data release];
  }
}

static void server_ui_clear(UI *ui __unused) {
  @autoreleasepool {
    server_ui_flush(NULL);
  }

  [_neovim_server sendMessageWithId:NvimServerMsgIdClear];
}

static void server_ui_eol_clear(UI *ui __unused) {
  @autoreleasepool {
    server_ui_flush(NULL);
  }

  [_neovim_server sendMessageWithId:NvimServerMsgIdEolClear];
}

static void server_ui_cursor_goto(UI *ui __unused, Integer row, Integer col) {
  @autoreleasepool {
    _put_row = row;
    _put_column = col;

    NSInteger values[] = {
        row, col,
        (NSInteger) curwin->w_cursor.lnum, curwin->w_cursor.col + 1
    };

    DLOG("%d:%d - %d:%d - %d:%d", values[0], values[1], values[2], values[3]);

    NSData *data = [[NSData alloc] initWithBytes:values length:(4 * sizeof(NSInteger))];
    add_to_render_data(RenderDataTypeGoto, data);
    [data release];
  }
}

static void server_ui_update_menu(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NvimServerMsgIdSetMenu];
}

static void server_ui_busy_start(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NvimServerMsgIdBusyStart];
}

static void server_ui_busy_stop(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NvimServerMsgIdBusyStop];
}

static void server_ui_mouse_on(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NvimServerMsgIdMouseOn];
}

static void server_ui_mouse_off(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NvimServerMsgIdMouseOff];
}

static void server_ui_mode_info_set(UI *ui __unused, Boolean enabled __unused,
                                    Array cursor_styles __unused) {
  // yet noop
}

static void server_ui_mode_change(UI *ui __unused, String mode_str __unused, Integer mode) {
  @autoreleasepool {
    NSInteger value = mode;
    NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(NSInteger))];
    [_neovim_server sendMessageWithId:NvimServerMsgIdModeChange data:data];
    [data release];
  }
}

static void server_ui_set_scroll_region(UI *ui __unused, Integer top, Integer bot,
                                        Integer left, Integer right) {

  @autoreleasepool {
    server_ui_flush(NULL);

    NSInteger values[] = {top, bot, left, right};
    NSData *data = [[NSData alloc] initWithBytes:values length:(4 * sizeof(NSInteger))];
    [_neovim_server sendMessageWithId:NvimServerMsgIdSetScrollRegion data:data];
    [data release];
  }
}

static void server_ui_scroll(UI *ui __unused, Integer count) {
  @autoreleasepool {
    server_ui_flush(NULL);

    NSInteger value = count;
    NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(NSInteger))];
    [_neovim_server sendMessageWithId:NvimServerMsgIdScroll data:data];
    [data release];
  }
}

static void server_ui_highlight_set(UI *ui __unused, HlAttrs attrs) {
  FontTrait trait = FontTraitNone;
  if (attrs.rgb_ae_attr & HL_ITALIC) {
    trait |= FontTraitItalic;
  }
  if (attrs.rgb_ae_attr & HL_BOLD) {
    trait |= FontTraitBold;
  }
  if (attrs.rgb_ae_attr & HL_UNDERLINE) {
    trait |= FontTraitUnderline;
  }
  if (attrs.rgb_ae_attr & HL_UNDERCURL) {
    trait |= FontTraitUndercurl;
  }
  CellAttributes cellAttrs;
  cellAttrs.fontTrait = trait;

  NSInteger fg = attrs.rgb_fg_color == -1 ? _default_foreground : attrs.rgb_fg_color;
  NSInteger bg = attrs.rgb_bg_color == -1 ? _default_background : attrs.rgb_bg_color;

  cellAttrs.foreground = attrs.rgb_ae_attr & HL_INVERSE ? bg : fg;
  cellAttrs.background = attrs.rgb_ae_attr & HL_INVERSE ? fg : bg;
  cellAttrs.special = attrs.rgb_sp_color == -1 ? _default_special : pun_type(unsigned int, attrs.rgb_sp_color);

  @autoreleasepool {
    NSData *data = [[NSData alloc] initWithBytes:&cellAttrs length:sizeof(CellAttributes)];
    add_to_render_data(RenderDataTypeHighlight, data);
    [data release];
  }
}

static void server_ui_put(UI *ui __unused, String str) {
  NSString *string = [[NSString alloc] initWithBytes:str.data
                                              length:str.size
                                            encoding:NSUTF8StringEncoding];

  @autoreleasepool {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];

    if (_marked_text != nil && _marked_row == _put_row && _marked_column == _put_column) {

      DLOG("putting marked text: '%s'", string.cstr);
      add_to_render_data(RenderDataTypePutMarked, data);

    } else if (_marked_text != nil
        && str.size == 0
        && _marked_row == _put_row
        && _marked_column == _put_column - 1) {

      DLOG("putting marked text cuz zero");
      add_to_render_data(RenderDataTypePutMarked, data);

    } else {

      DLOG("putting non-marked text: '%s'", string.cstr);
      add_to_render_data(RenderDataTypePut, data);

    }

    _put_column += 1;

    [string release];
  }
}

static void server_ui_bell(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NvimServerMsgIdBell];
}

static void server_ui_visual_bell(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NvimServerMsgIdVisualBell];
}

static void server_ui_update_fg(UI *ui __unused, Integer fg) {
  @autoreleasepool {
    NSInteger value[1];

    if (fg == -1) {
      value[0] = _default_foreground;
      NSData *data = [[NSData alloc] initWithBytes:value length:(1 * sizeof(NSInteger))];
      [_neovim_server sendMessageWithId:NvimServerMsgIdSetForeground data:data];
      [data release];

      return;
    }

    _default_foreground = fg;

    value[0] = fg;
    NSData *data = [[NSData alloc] initWithBytes:value length:(1 * sizeof(NSInteger))];
    [_neovim_server sendMessageWithId:NvimServerMsgIdSetForeground data:data];
    [data release];
  }
}

static void server_ui_update_bg(UI *ui __unused, Integer bg) {
  @autoreleasepool {
    NSInteger value[1];

    if (bg == -1) {
      value[0] = _default_background;
      NSData *data = [[NSData alloc] initWithBytes:value length:(1 * sizeof(NSInteger))];
      [_neovim_server sendMessageWithId:NvimServerMsgIdSetBackground data:data];
      [data release];

      return;
    }

    _default_background = bg;
    value[0] = bg;
    NSData *data = [[NSData alloc] initWithBytes:value length:(1 * sizeof(NSInteger))];
    [_neovim_server sendMessageWithId:NvimServerMsgIdSetBackground data:data];
    [data release];
  }
}

static void server_ui_update_sp(UI *ui __unused, Integer sp) {
  @autoreleasepool {
    NSInteger value[2];

    if (sp == -1) {
      value[0] = _default_special;
      NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(NSInteger))];
      [_neovim_server sendMessageWithId:NvimServerMsgIdSetSpecial data:data];
      [data release];

      return;
    }

    _default_special = sp;
    value[0] = sp;
    NSData *data = [[NSData alloc] initWithBytes:&value length:(1 * sizeof(NSInteger))];
    [_neovim_server sendMessageWithId:NvimServerMsgIdSetSpecial data:data];
    [data release];
  }
}

static void server_ui_default_colors_set(
    UI *ui __unused, Integer rgb_fg, Integer rgb_bg, Integer rgb_sp, Integer cterm_fg, Integer cterm_bg
) {

  if (rgb_fg != -1) {
    _default_foreground = rgb_fg;
  }

  if (rgb_bg != -1) {
    _default_background = rgb_bg;
  }

  if (rgb_sp != -1) {
    _default_special = rgb_sp;
  }

  NSInteger values[] = { rgb_fg, rgb_bg, rgb_sp };
  NSData *resultData = [NSData dataWithBytes:values length:3 * sizeof(NSInteger)];
  
  [_neovim_server sendMessageWithId:NvimServerMsgIdDefaultColorsChanged data:resultData];
}

static void server_ui_set_title(UI *ui __unused, String title) {
  @autoreleasepool {
    if (title.size == 0) {
      return;
    }

    NSString *string = [[NSString alloc] initWithCString:title.data encoding:NSUTF8StringEncoding];
    [_neovim_server sendMessageWithId:NvimServerMsgIdSetTitle
                                 data:[string dataUsingEncoding:NSUTF8StringEncoding]];
    [string release];
  }
}

static void server_ui_set_icon(UI *ui __unused, String icon) {
  @autoreleasepool {
    if (icon.size == 0) {
      return;
    }

    NSString *string = [[NSString alloc] initWithCString:icon.data encoding:NSUTF8StringEncoding];
    [_neovim_server sendMessageWithId:NvimServerMsgIdSetIcon
                                 data:[string dataUsingEncoding:NSUTF8StringEncoding]];
    [string release];
  }
}

static void server_ui_option_set(UI *ui __unused, String name, Object value) {
  // yet noop
  // FIXME: implement before nvim 0.2.3 is released...
}

static void server_ui_stop(UI *ui __unused) {
  [_neovim_server sendMessageWithId:NvimServerMsgIdStop];

  ServerUiData *data = (ServerUiData *) ui->data;
  data->stop = true;
}

#pragma mark Public
// called by neovim

void custom_ui_start(void) {
  UI *ui = xcalloc(1, sizeof(UI));

  ui->rgb = true;
  ui->stop = server_ui_stop;
  ui->resize = server_ui_resize;
  ui->clear = server_ui_clear;
  ui->eol_clear = server_ui_eol_clear;
  ui->cursor_goto = server_ui_cursor_goto;
  ui->update_menu = server_ui_update_menu;
  ui->busy_start = server_ui_busy_start;
  ui->busy_stop = server_ui_busy_stop;
  ui->mouse_on = server_ui_mouse_on;
  ui->mouse_off = server_ui_mouse_off;
  ui->mode_info_set = server_ui_mode_info_set;
  ui->mode_change = server_ui_mode_change;
  ui->set_scroll_region = server_ui_set_scroll_region;
  ui->scroll = server_ui_scroll;
  ui->highlight_set = server_ui_highlight_set;
  ui->default_colors_set = server_ui_default_colors_set;
  ui->put = server_ui_put;
  ui->bell = server_ui_bell;
  ui->visual_bell = server_ui_visual_bell;
  ui->update_fg = server_ui_update_fg;
  ui->update_bg = server_ui_update_bg;
  ui->update_sp = server_ui_update_sp;
  ui->flush = server_ui_flush;
  ui->suspend = NULL;
  ui->set_title = server_ui_set_title;
  ui->set_icon = server_ui_set_icon;
  ui->option_set = server_ui_option_set;

  ui_bridge_attach(ui, server_ui_main, server_ui_scheduler);
}

void custom_ui_autocmds_groups(
    event_T event,
    char_u *fname __unused,
    char_u *fname_io __unused,
    int group __unused,
    bool force __unused,
    buf_T *buf,
    exarg_T *eap __unused
) {
  // We don't need these events in the UI (yet) and they slow down scrolling: Enable them,
  // if necessary, only after optimizing the scrolling.
  if (event == EVENT_CURSORMOVED || event == EVENT_CURSORMOVEDI) {
    return;
  }

  @autoreleasepool {
    DLOG("got event %d for file %s in group %d.", event, fname, group);

    if (event == EVENT_DIRCHANGED) {
      send_cwd();
      return;
    }

    if (event == EVENT_COLORSCHEME) {
      send_colorscheme();
      return;
    }

    if (event == EVENT_TEXTCHANGED
      || event == EVENT_TEXTCHANGEDI
      || event == EVENT_BUFWRITEPOST
      || event == EVENT_BUFLEAVE)
    {
      send_dirty_status();
    }

    NSInteger eventCode = (NSInteger) event;

    NSMutableData *data;
    if (buf == NULL) {
      data = [[NSMutableData alloc] initWithBytes:&eventCode length:sizeof(NSInteger)];
    } else {
      NSInteger bufHandle = buf->handle;

      data = [[NSMutableData alloc] initWithCapacity:(sizeof(NSInteger) + sizeof(NSInteger))];
      [data appendBytes:&eventCode length:sizeof(NSInteger)];
      [data appendBytes:&bufHandle length:sizeof(NSInteger)];
    }

    [_neovim_server sendMessageWithId:NvimServerMsgIdAutoCommandEvent data:data];

    [data release];
  }
}

#pragma mark Other help functions
void start_neovim(NSInteger width, NSInteger height, NSArray<NSString *> *args) {
  _initialWidth = width;
  _initialHeight = height;

  // set $VIMRUNTIME to ${RESOURCE_PATH_OF_XPC_BUNDLE}/runtime
  NSString *bundlePath = [NSBundle bundleForClass:[NvimServer class]].bundlePath;
  NSString *resourcesPath = [bundlePath.stringByDeletingLastPathComponent
      stringByAppendingPathComponent:@"Resources"];
  NSString *runtimePath = [resourcesPath stringByAppendingPathComponent:@"runtime"];
  setenv("VIMRUNTIME", runtimePath.fileSystemRepresentation, true);

  // Set $LANG to en_US.UTF-8 such that the copied text to the system clipboard is not garbled.
  setenv("LANG", "en_US.UTF-8", true);

  uv_mutex_init(&_mutex);
  uv_cond_init(&_condition);

  uv_thread_create(&_nvim_thread, run_neovim, [args retain]); // released in run_neovim()
  DLOG("NeoVim started");

  // continue only after our UI main code for neovim has been fully initialized
  uv_mutex_lock(&_mutex);
  while (!_is_ui_launched) {
    uv_cond_wait(&_condition, &_mutex);
  }
  uv_mutex_unlock(&_mutex);

  uv_cond_destroy(&_condition);
  uv_mutex_destroy(&_mutex);

  _backspace = [[NSString alloc] initWithString:@"<BS>"];

  bool value = msg_didany > 0;
  NSData *data = [[NSData alloc] initWithBytes:&value length:sizeof(bool)];
  [_neovim_server sendMessageWithId:NvimServerMsgIdNvimReady data:data];
  [data release];
}

#pragma mark Functions for neovim's main loop

typedef NSData *(^work_block)(NSData *);

static void work_and_write_data_sync(void **argv, work_block block) {
  @autoreleasepool {
    NSCondition *outputCondition = argv[1];
    [outputCondition lock];

    NSData *data = argv[0];
    DataWrapper *wrapper = argv[2];
    wrapper.data = block(data);
    wrapper.dataReady = YES;
    [data release]; // retained in local_server_callback

    [outputCondition signal];
    [outputCondition unlock];
  }
}

//static void work_async(void **argv, work_block block) {
//  @autoreleasepool {
//    NSData *data = argv[0];
//    block(data);
//    [data release]; // retained in local_server_callback
//  }
//}

static NSString *escaped_filename(NSString *filename) {
  const char *file_system_rep = filename.fileSystemRepresentation;

  char *escaped_filename = vim_strsave_fnameescape(file_system_rep, 0);
  NSString *result = [NSString stringWithCString:(const char *) escaped_filename
                                        encoding:NSUTF8StringEncoding];
  xfree(escaped_filename);

  return result;
}

void neovim_scroll(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSInteger *values = (NSInteger *) data.bytes;
    int horiz = (int) values[0];
    int vert = (int) values[1];
    int row = (int) values[2];
    int column = (int) values[3];

    if (horiz == 0 && vert == 0) {
      return nil;
    }

    if (row < 0 || column < 0) {
      row = 0;
      column = 0;
    }

    // value > 0 => down or right
    int horizDir;
    int vertDir;
    if (horiz != 0) {
      horizDir = horiz > 0 ? MSCR_RIGHT: MSCR_LEFT;
      custom_ui_scroll(horizDir, ABS(horiz), row, column);
    }
    if (vert != 0) {
      vertDir = vert > 0 ? MSCR_DOWN: MSCR_UP;
      custom_ui_scroll(vertDir, ABS(vert), row, column);
    }

    refresh_ui_screen(VALID);

    return nil;
  });
}

void neovim_resize(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    const NSInteger *values = data.bytes;
    NSInteger width = values[0];
    NSInteger height = values[1];

    set_ui_size(_server_ui_data->bridge, (int) width, (int) height);
    ui_refresh();

    return nil;
  });
}

void neovim_vim_input(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSString *input = [[[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding] autorelease];

    if (_marked_text == nil) {
      nvim_input(vim_string_from(input));
      return nil;
    }

    // Handle cases like ㅎ -> arrow key: The previously marked text is the same as the finalized
    // text which should inserted. Neovim's drawing code is optimized such that it does not call
    // put in this case again, thus, we have to manually unmark the cells in the main app.
    if ([_marked_text isEqualToString:input]) {
      DLOG("unmarking text: '%s'\t now at %d:%d", input.cstr, _put_row, _put_column);
      const char *str = _marked_text.cstr;
      size_t cellCount = mb_string2cells((const char_u *) str);

      for (int i = 1; i <= cellCount; i++) {
        DLOG("unmarking at %d:%d", _put_row, _put_column - i);
        NSInteger values[] = {_put_row, MAX(_put_column - i, 0)};

        NSData *unmarkData = [[NSData alloc] initWithBytes:values length:(2 * sizeof(NSInteger))];
        [_neovim_server sendMessageWithId:NvimServerMsgIdUnmark data:unmarkData];
        [unmarkData release];
      }
    }

    delete_marked_text();
    nvim_input(vim_string_from(input));

    return nil;
  });
}

void neovim_vim_input_marked_text(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSString *markedText = [[[NSString alloc] initWithData:data
                                                  encoding:NSUTF8StringEncoding] autorelease];

    if (_marked_text == nil) {
      _marked_row = _put_row;
      _marked_column = _put_column + _marked_delta;
      DLOG(
        "marking position: %d:%d(%d + %d)", _put_row, _marked_column, _put_column, _marked_delta
      );
      _marked_delta = 0;
    } else {
      delete_marked_text();
    }

    DLOG("inserting marked text '%s' at %d:%d", markedText.cstr, _put_row, _put_column);
    insert_marked_text(markedText);

    return nil;
  });
}

void neovim_delete(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    const NSInteger *values = data.bytes;
    NSInteger count = values[0];

    _marked_delta = 0;

    // Very ugly: When we want to have the Hanja for 하, Cocoa first finalizes 하, then sets
    // the Hanja as marked text. The main app will call this method when this happens,
    // thus compute how many cell we have to go backward to correctly
    // mark the will-be-soon-inserted Hanja... See also docs/notes-on-cocoa-text-input.md
    int emptyCounter = 0;
    for (int i = 0; i < count; i++) {
      _marked_delta -= 1;

      // TODO: -1 because we assume that the cursor is one cell ahead,
      // probably not always correct...
      schar_T character = ScreenLines[_put_row * screen_Rows + _put_column - i - emptyCounter - 1];
      if (character == 0x00 || character == ' ') {
        // FIXME: dunno yet, why we have to also match ' '...
        _marked_delta -= 1;
        emptyCounter += 1;
      }
    }

    DLOG("put cursor: %d:%d, count: %li, delta: %d", _put_row, _put_column, count, _marked_delta);

    for (int i = 0; i < count; i++) {
      nvim_input(vim_string_from(_backspace));
    }

    return nil;
  });
}

void neovim_focus_gained(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    const bool *values = data.bytes;

    aucmd_schedule_focusgained(values[0]);

    return nil;
  });
}

void neovim_debug1(void **argv) {
  work_and_write_data_sync(argv, ^NSData *(NSData *data) {
    NSLog(@"normal fg: %#08X", normal_fg);
    NSLog(@"normal bg: %#08X", normal_bg);
    NSLog(@"normal sp: %#08X", normal_sp);

    for (int i = 0; i < HLF_COUNT; i++) {
      NSLog(@"%s: %#08X", hlf_names[i], HlAttrsFromAttrCode(highlight_attr[i]).rgb_fg_color);
    }

    return nil;
  });
}
