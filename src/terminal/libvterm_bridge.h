#ifndef NOREN_LIBVTERM_BRIDGE_H
#define NOREN_LIBVTERM_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef struct NorenVTerm NorenVTerm;

enum {
    NOREN_CELL_BOLD = 1 << 0,
    NOREN_CELL_UNDERLINE = 1 << 1,
    NOREN_CELL_ITALIC = 1 << 2,
    NOREN_CELL_REVERSE = 1 << 3,
    NOREN_CELL_STRIKE = 1 << 4,
};

enum {
    NOREN_COLOR_DEFAULT = 0,
    NOREN_COLOR_INDEXED = 1,
    NOREN_COLOR_RGB = 2,
};

enum {
    NOREN_MOD_SHIFT = 1 << 0,
    NOREN_MOD_ALT = 1 << 1,
    NOREN_MOD_CTRL = 1 << 2,
};

typedef struct {
    uint8_t kind;
    uint8_t first;
    uint8_t second;
    uint8_t third;
} NorenVTermColor;

typedef struct {
    uint32_t chars[6];
    uint8_t width;
    uint8_t attrs;
    NorenVTermColor foreground;
    NorenVTermColor background;
} NorenVTermCell;

NorenVTerm *noren_vterm_new(int rows, int cols);
void noren_vterm_free(NorenVTerm *terminal);
size_t noren_vterm_feed(NorenVTerm *terminal, const uint8_t *bytes, size_t len);
void noren_vterm_resize(NorenVTerm *terminal, int rows, int cols);
int noren_vterm_get_cell(
    const NorenVTerm *terminal,
    int row,
    int col,
    NorenVTermCell *cell
);
void noren_vterm_get_cursor(
    const NorenVTerm *terminal,
    int *row,
    int *col,
    int *visible
);
void noren_vterm_mouse(
    NorenVTerm *terminal,
    int row,
    int col,
    int button,
    int pressed,
    int modifiers
);
size_t noren_vterm_read_output(
    NorenVTerm *terminal,
    uint8_t *buffer,
    size_t capacity
);
const char *noren_vterm_title(const NorenVTerm *terminal);
int noren_vterm_take_damage(NorenVTerm *terminal);

#endif
