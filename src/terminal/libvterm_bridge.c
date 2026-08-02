#include "libvterm_bridge.h"

#include <stdlib.h>
#include <string.h>

#include "vterm.h"

struct NorenVTerm {
    VTerm *terminal;
    VTermScreen *screen;
    int cursor_row;
    int cursor_col;
    int cursor_visible;
    int damaged;
    char title[256];
    size_t title_length;
};

static int on_damage(VTermRect rect, void *user) {
    NorenVTerm *terminal = user;
    (void)rect;
    terminal->damaged = 1;
    return 1;
}

static int on_move_cursor(
    VTermPos position,
    VTermPos old_position,
    int visible,
    void *user
) {
    NorenVTerm *terminal = user;
    (void)old_position;
    terminal->cursor_row = position.row;
    terminal->cursor_col = position.col;
    terminal->cursor_visible = visible;
    return 1;
}

static int on_term_property(VTermProp property, VTermValue *value, void *user) {
    NorenVTerm *terminal = user;
    if (property == VTERM_PROP_CURSORVISIBLE) {
        terminal->cursor_visible = value->boolean;
        terminal->damaged = 1;
        return 1;
    }
    if (property != VTERM_PROP_TITLE) {
        return 1;
    }

    if (value->string.initial) {
        terminal->title_length = 0;
    }
    const size_t available = sizeof(terminal->title) - 1 - terminal->title_length;
    const size_t copy_length = value->string.len < available
        ? value->string.len
        : available;
    if (copy_length > 0) {
        memcpy(
            terminal->title + terminal->title_length,
            value->string.str,
            copy_length
        );
        terminal->title_length += copy_length;
    }
    terminal->title[terminal->title_length] = '\0';
    return 1;
}

static int on_bell(void *user) {
    (void)user;
    return 1;
}

static int on_resize(int rows, int cols, void *user) {
    NorenVTerm *terminal = user;
    (void)rows;
    (void)cols;
    terminal->damaged = 1;
    return 1;
}

static int on_scrollback_push(
    int cols,
    const VTermScreenCell *cells,
    void *user
) {
    (void)cols;
    (void)cells;
    (void)user;
    return 0;
}

static int on_scrollback_pop(int cols, VTermScreenCell *cells, void *user) {
    (void)cols;
    (void)cells;
    (void)user;
    return 0;
}

static int on_scrollback_clear(void *user) {
    (void)user;
    return 1;
}

static const VTermScreenCallbacks callbacks = {
    .damage = on_damage,
    .moverect = NULL,
    .movecursor = on_move_cursor,
    .settermprop = on_term_property,
    .bell = on_bell,
    .resize = on_resize,
    .sb_pushline = on_scrollback_push,
    .sb_popline = on_scrollback_pop,
    .sb_clear = on_scrollback_clear,
};

NorenVTerm *noren_vterm_new(int rows, int cols) {
    if (rows < 1 || cols < 1) {
        return NULL;
    }
    NorenVTerm *result = calloc(1, sizeof(*result));
    if (result == NULL) {
        return NULL;
    }
    result->terminal = vterm_new(rows, cols);
    if (result->terminal == NULL) {
        free(result);
        return NULL;
    }
    vterm_set_utf8(result->terminal, 1);
    result->screen = vterm_obtain_screen(result->terminal);
    if (result->screen == NULL) {
        vterm_free(result->terminal);
        free(result);
        return NULL;
    }
    result->cursor_visible = 1;
    vterm_screen_set_callbacks(result->screen, &callbacks, result);
    vterm_screen_enable_altscreen(result->screen, 1);
    vterm_screen_set_damage_merge(result->screen, VTERM_DAMAGE_ROW);
    vterm_screen_reset(result->screen, 1);
    return result;
}

void noren_vterm_free(NorenVTerm *terminal) {
    if (terminal == NULL) {
        return;
    }
    vterm_free(terminal->terminal);
    free(terminal);
}

size_t noren_vterm_feed(NorenVTerm *terminal, const uint8_t *bytes, size_t len) {
    const size_t consumed = vterm_input_write(
        terminal->terminal,
        (const char *)bytes,
        len
    );
    vterm_screen_flush_damage(terminal->screen);
    return consumed;
}

void noren_vterm_resize(NorenVTerm *terminal, int rows, int cols) {
    vterm_set_size(terminal->terminal, rows, cols);
    vterm_screen_flush_damage(terminal->screen);
}

static NorenVTermColor flatten_color(const VTermColor *color) {
    NorenVTermColor result = {0};
    if (VTERM_COLOR_IS_DEFAULT_FG(color) ||
        VTERM_COLOR_IS_DEFAULT_BG(color)) {
        result.kind = NOREN_COLOR_DEFAULT;
    } else if (VTERM_COLOR_IS_INDEXED(color)) {
        result.kind = NOREN_COLOR_INDEXED;
        result.first = color->indexed.idx;
    } else {
        result.kind = NOREN_COLOR_RGB;
        result.first = color->rgb.red;
        result.second = color->rgb.green;
        result.third = color->rgb.blue;
    }
    return result;
}

int noren_vterm_get_cell(
    const NorenVTerm *terminal,
    int row,
    int col,
    NorenVTermCell *cell
) {
    VTermScreenCell source = {0};
    if (!vterm_screen_get_cell(
        terminal->screen,
        (VTermPos){ .row = row, .col = col },
        &source
    )) {
        return 0;
    }
    memset(cell, 0, sizeof(*cell));
    memcpy(cell->chars, source.chars, sizeof(cell->chars));
    cell->width = (uint8_t)source.width;
    if (source.chars[0] == UINT32_MAX) {
        cell->chars[0] = 0;
        cell->width = 0;
    }
    if (source.attrs.bold) cell->attrs |= NOREN_CELL_BOLD;
    if (source.attrs.underline) cell->attrs |= NOREN_CELL_UNDERLINE;
    if (source.attrs.italic) cell->attrs |= NOREN_CELL_ITALIC;
    if (source.attrs.reverse) cell->attrs |= NOREN_CELL_REVERSE;
    if (source.attrs.strike) cell->attrs |= NOREN_CELL_STRIKE;
    cell->foreground = flatten_color(&source.fg);
    cell->background = flatten_color(&source.bg);
    return 1;
}

void noren_vterm_get_cursor(
    const NorenVTerm *terminal,
    int *row,
    int *col,
    int *visible
) {
    if (row != NULL) *row = terminal->cursor_row;
    if (col != NULL) *col = terminal->cursor_col;
    if (visible != NULL) *visible = terminal->cursor_visible;
}

void noren_vterm_mouse(
    NorenVTerm *terminal,
    int row,
    int col,
    int button,
    int pressed,
    int modifiers
) {
    if (terminal == NULL || row < 0 || col < 0 || button < 1) {
        return;
    }
    const VTermModifier modifier = (VTermModifier)(
        modifiers & VTERM_ALL_MODS_MASK
    );
    vterm_mouse_move(terminal->terminal, row, col, modifier);
    vterm_mouse_button(terminal->terminal, button, pressed != 0, modifier);
}

size_t noren_vterm_read_output(
    NorenVTerm *terminal,
    uint8_t *buffer,
    size_t capacity
) {
    return vterm_output_read(terminal->terminal, (char *)buffer, capacity);
}

const char *noren_vterm_title(const NorenVTerm *terminal) {
    return terminal->title;
}

int noren_vterm_take_damage(NorenVTerm *terminal) {
    const int damaged = terminal->damaged;
    terminal->damaged = 0;
    return damaged;
}
