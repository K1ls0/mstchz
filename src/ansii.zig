pub const esc = "\x1b";
pub const rst = esc ++ "[0m";
pub const bold = esc ++ "[1m";
pub const underline = esc ++ "[4m";
pub const no_underline = esc ++ "[24m";
pub const reverse_text = esc ++ "[7m";
pub const no_reverse_text = esc ++ "[27m";

pub const bg = struct {
    pub const black = esc ++ "[40m";
    pub const dark_red = esc ++ "[41m";
    pub const dark_green = esc ++ "[42m";
    pub const dark_yellow = esc ++ "[43m";
    pub const dark_blue = esc ++ "[44m";
    pub const dark_magenta = esc ++ "[45m";
    pub const dark_cyan = esc ++ "[46m";
    pub const dark_white = esc ++ "[47m";

    pub const bright_black = esc ++ "[100m";
    pub const bright_red = esc ++ "[101m";
    pub const bright_green = esc ++ "[102m";
    pub const bright_yellow = esc ++ "[103m";
    pub const bright_blue = esc ++ "[104m";
    pub const bright_magenta = esc ++ "[105m";
    pub const bright_cyan = esc ++ "[106m";
    pub const bright_white = esc ++ "[107m";
};
pub const fg = struct {
    pub const black = esc ++ "[31m";
    pub const dark_red = esc ++ "[31m";
    pub const dark_green = esc ++ "[32m";
    pub const dark_yellow = esc ++ "[33m";
    pub const dark_blue = esc ++ "[34m";
    pub const dark_magenta = esc ++ "[35m";
    pub const dark_cyan = esc ++ "[36m";
    pub const dark_white = esc ++ "[37m";

    pub const bright_black = esc ++ "[90m";
    pub const bright_red = esc ++ "[91m";
    pub const bright_green = esc ++ "[92m";
    pub const bright_yellow = esc ++ "[93m";
    pub const bright_blue = esc ++ "[94m";
    pub const bright_magenta = esc ++ "[95m";
    pub const bright_cyan = esc ++ "[96m";
    pub const bright_white = esc ++ "[97m";
};
