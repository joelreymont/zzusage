\ Local JSONL usage reports, matching zzusage's CLI.
require lib/string.f
require lib/fs.f
require lib/fs-list.f
require lib/date.f
require lib/fmath.f
require lib/f64-text.f
require lib/process.f
require lib/sort.f

package ZU

536870912 constant FILE-CAP
10 constant LF

DYNAMIC-BUFFER FILE-BUF u8
DYNAMIC-BUFFER STRING-POOL u8
variable POOL-U
create PATH-BUF FS-PATH-CAP allot
create HOME-DIR-A FS-PATH-CAP allot
create HOME-DIR-B FS-PATH-CAP allot
variable PROJECTS-U
PTR-VARIABLE PROJECT-P
variable PROJECT-U
variable PATH-U
PTR-VARIABLE TIMESTAMP-P
variable TIMESTAMP-U
PTR-VARIABLE MODEL-P
variable MODEL-U
PTR-VARIABLE SESSION-P
variable SESSION-U
create DATE-BUF 16 allot
variable DATE-U
create MONEY-BUF 2 allot
create DECIMAL-BUF F64-TEXT:MAX-BYTES allot
variable MONEY-POS
create LF-BYTE 10 c,
create QUOTE-BYTE 34 c,
create COLON-BYTE 58 c,
create U64-BUF 20 allot
variable U64-INDEX
DYNAMIC-BUFFER TEXT-BUF u8
variable TEXT-U
4096 constant OUT-CAP
create OUT-BUF OUT-CAP allot
variable OUT-U

DYNAMIC-BUFFER DIR-A ptr u8
DYNAMIC-BUFFER DIR-U n
variable DIR-COUNT
variable MODE
variable JSON-FLAG
variable TIMEZONE-MIN
variable KEY-FIELD
variable SCAN-POS
variable TIME-VALID
variable FILE-FD
variable FILE-U
variable FILE-READ
variable FILE-ALLOC
create FILE-PROBE 1 allot
variable STATUS-INDEX
variable STATUS-TS
variable DATE-REMAIN
variable DATE-YEAR
variable DATE-MONTH


variable INPUT-N
variable OUTPUT-N
variable CREATE-N
variable READ-N
variable HAS-INPUT
variable HAS-COST
TYPED-VARIABLE COST-EXPLICIT r

DYNAMIC-BUFFER ROW-KEY-OFF n
DYNAMIC-BUFFER ROW-KEY-U n
DYNAMIC-BUFFER ROW-PROJECT-OFF n
DYNAMIC-BUFFER ROW-PROJECT-U n
DYNAMIC-BUFFER ROW-IN n
DYNAMIC-BUFFER ROW-OUT n
DYNAMIC-BUFFER ROW-CREATE n
DYNAMIC-BUFFER ROW-READ n
DYNAMIC-BUFFER ROW-LAST n
DYNAMIC-BUFFER ROW-COST r
DYNAMIC-BUFFER ROW-ORDER n
DYNAMIC-BUFFER ROW-RANK n
DYNAMIC-BUFFER ROW-SLOTS n
DYNAMIC-BUFFER ROW-SLOTS-OLD n
DYNAMIC-BUFFER ROW-MODEL-HEAD n
DYNAMIC-BUFFER ROW-MODEL-TAIL n
DYNAMIC-BUFFER ROW-PROJECT-HEAD n
DYNAMIC-BUFFER ROW-PROJECT-TAIL n
DYNAMIC-BUFFER ROW-MODEL-SIZE n
DYNAMIC-BUFFER ROW-MODEL-CAP n
DYNAMIC-BUFFER ROW-PROJECT-SIZE n
DYNAMIC-BUFFER ROW-PROJECT-CAP n
variable ROW-COUNT
variable ROW-MAP-CAP
DYNAMIC-BUFFER SET-ROW n
DYNAMIC-BUFFER SET-KIND n
DYNAMIC-BUFFER SET-OFF n
DYNAMIC-BUFFER SET-U n
DYNAMIC-BUFFER SET-NEXT n
DYNAMIC-BUFFER SET-SLOTS n
DYNAMIC-BUFFER SET-SLOTS-OLD n
variable SET-CAP
variable SET-COUNT

: FALSE-FLAG ( -- bool ) 0 0= 0= ;
: ERROR-EXIT ( ptr u8 n -- )
   \ If stderr is closed, preserve the failure status without another write.
   [: 2 >FD FD-NOSIGPIPE! ;] catch 0<> if 2drop s" " 1 die then
   1 die ;
: CAPACITY-FAIL ( -- ) s" zzusage-habu: input capacity exceeded" ERROR-EXIT ;
: WRITE-FAIL ( -- ) s" error: WriteFailed" ERROR-EXIT ;
: WRITE-ALL ( ptr u8 n -- )
   begin dup 0 > while
      2dup 1 -rot write dup 0 <= if drop 2drop WRITE-FAIL then
      >r swap r@ + swap r> -
   repeat 2drop ;
: OUT-FLUSH ( -- )
   OUT-U @ 0 > if OUT-BUF OUT-U @ WRITE-ALL 0 OUT-U ! then ;
: OUT ( ptr u8 n -- ) {: a:ptr u:n :}
   u OUT-CAP OUT-U @ - > if OUT-FLUSH then
   u OUT-CAP >= if a u WRITE-ALL exit then
   a OUT-BUF OUT-U @ + u BYTE-COPY
   u OUT-U +! ;
: OUT-LF ( -- ) LF-BYTE 1 OUT ;
: HELP-OUT ( ptr u8 n -- )
   begin dup 0 > while
      2dup 1 -rot write dup 0 <= if drop 2drop exit then
      >r swap r@ + swap r> -
   repeat 2drop ;
: HELP-LF ( -- ) LF-BYTE 1 HELP-OUT ;
: ARG-FAIL ( -- ) s" zzusage-habu: invalid arguments" ERROR-EXIT ;
: HELP ( -- )
   s" zzusage - Claude Code usage analyzer (Zig)" HELP-OUT HELP-LF
   HELP-LF
   s" Usage: zzusage [command] [options]" HELP-OUT HELP-LF
   HELP-LF
   s" Commands:" HELP-OUT HELP-LF
   s"   daily       Daily usage (default)" HELP-OUT HELP-LF
   s"   weekly      Weekly usage" HELP-OUT HELP-LF
   s"   monthly     Monthly usage" HELP-OUT HELP-LF
   s"   sessions    Per-session usage" HELP-OUT HELP-LF
   s"   blocks      5-hour block usage" HELP-OUT HELP-LF
   s"   statusline  One-line summary" HELP-OUT HELP-LF
   HELP-LF
   s" Options:" HELP-OUT HELP-LF
   s"   --data-dir <path>   Data directory (repeatable)" HELP-OUT HELP-LF
   s"   --json              JSON output" HELP-OUT HELP-LF
   s"   --compact           Compact display" HELP-OUT HELP-LF
   s"   --breakdown         Show model breakdowns" HELP-OUT HELP-LF
   s"   --order asc|desc    Sort order" HELP-OUT HELP-LF
   s"   --timezone +HH:MM   Timezone offset" HELP-OUT HELP-LF
   s"   --help              Show this help" HELP-OUT HELP-LF ;

: ARG-VALUE ( n -- ptr u8 n )
   1+ dup SCRIPT-ARGC >= if drop ARG-FAIL then SCRIPT-ARGV$ ;

: DIGIT ( ptr u8 n -- n ) {: a:ptr at:n :}
   a at + c@ dup 48 < over 57 > or if drop ARG-FAIL then 48 - ;

: TZ-NUM ( ptr u8 n n -- n ) {: a:ptr u:n at:n :}
   at 2 + u > if 0 exit then
   a at + 2 STR>NUMBER? MATCH option
      none OF 0 ENDOF
      some OF ENDOF
   ;MATCH ;

: TZ-PARSE ( ptr u8 n -- n ) {: a:ptr u:n :}
   u 5 < if 0 exit then
   a c@ 45 = if -1 else 1 then {: sign:n :}
   a c@ 43 = a c@ 45 = or if 1 else 0 then {: start:n :}
   a u start TZ-NUM 60 * a u start 3 + TZ-NUM + sign * ;

: ADD-DIR ( ptr u8 n -- ) {: a:ptr u:n :}
   DIR-COUNT @ 1+ DIR-A-RESERVE
   DIR-COUNT @ 1+ DIR-U-RESERVE
   a DIR-COUNT @ DIR-A !
   u DIR-COUNT @ DIR-U !
   DIR-COUNT @ 1+ DIR-COUNT ! ;

0 constant DAILY
1 constant MONTHLY
2 constant SESSIONS
3 constant STATUSLINE
4 constant HELP-MODE

: PARSE-ARG ( n -- n ) {: idx:n :}
   idx SCRIPT-ARGV$ {: a:ptr u:n :}
   a u s" help" STR= a u s" -h" STR= or a u s" --help" STR= or if HELP-MODE MODE ! idx exit then
   a u s" daily" STR= if DAILY MODE ! idx exit then
   a u s" weekly" STR= if DAILY MODE ! idx exit then
   a u s" blocks" STR= if DAILY MODE ! idx exit then
   a u s" monthly" STR= if MONTHLY MODE ! idx exit then
   a u s" sessions" STR= if SESSIONS MODE ! idx exit then
   a u s" statusline" STR= if STATUSLINE MODE ! idx exit then
   a u s" --json" STR= if 1 JSON-FLAG ! idx exit then
   a u s" --compact" STR= if idx exit then
   a u s" --breakdown" STR= if idx exit then
   a u s" --data-dir" STR= if idx 1+ SCRIPT-ARGC < if idx ARG-VALUE ADD-DIR idx 1+ exit then then
   a u s" --timezone" STR= if idx 1+ SCRIPT-ARGC < if idx ARG-VALUE TZ-PARSE TIMEZONE-MIN ! idx 1+ exit then then
   a u s" --order" STR= if idx 1+ SCRIPT-ARGC < if idx 1+ exit then then
   idx ;

: PARSE-ARGS ( -- )
   0 MODE ! 0 JSON-FLAG ! 0 DIR-COUNT ! 0 TIMEZONE-MIN !
   0 begin dup SCRIPT-ARGC < while PARSE-ARG 1+ repeat drop
   MODE @ HELP-MODE <> DIR-COUNT @ 0= and if
      s" HOME" GETENV {: h:ptr hu:n :}
      hu 0 > if
         h hu 1- + c@ 47 = if 0 else 1 then {: sep:n :}
         hu sep + 14 + FS-PATH-CAP <= if
            HOME-DIR-A h hu s" .config/claude" HOME-DIR-A JOIN-PATH ADD-DIR
         then
         hu sep + 7 + FS-PATH-CAP <= if
            HOME-DIR-B h hu s" .claude" HOME-DIR-B JOIN-PATH ADD-DIR
         then
      then
   then ;

: MODEL-BASE ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   a u s" anthropic/" STARTS-WITH? if a 10 + u 10 - else a u then
   {: b:ptr v:n :}
   b v s" openrouter/" STARTS-WITH? if b 11 + v 11 - else b v then
   {: c:ptr w:n :}
   c w s" openai/" STARTS-WITH? if c 7 + w 7 - else c w then ;

: PRICE-RATES ( ptr u8 n -- r r r r ) {: a:ptr u:n :}
   a u s" claude-opus-4-5" STARTS-WITH? if 5.0 25.0 6.25 0.5 exit then
   a u s" claude-sonnet-4-5" STARTS-WITH? if 3.0 15.0 3.75 0.3 exit then
   a u s" claude-haiku-4-5" STARTS-WITH? if 1.0 5.0 1.25 0.1 exit then
   a u s" claude-opus-4-1" STARTS-WITH? if 15.0 75.0 18.75 1.5 exit then
   a u s" claude-opus-4" STARTS-WITH? if 15.0 75.0 18.75 1.5 exit then
   a u s" claude-sonnet-4" STARTS-WITH? if 3.0 15.0 3.75 0.3 exit then
   a u s" claude-3-5-sonnet" STARTS-WITH? if 3.0 15.0 3.75 0.3 exit then
   a u s" claude-3-5-haiku" STARTS-WITH? if 0.8 4.0 1.0 0.08 exit then
   a u s" claude-3-opus" STARTS-WITH? if 15.0 75.0 18.75 1.5 exit then
   a u s" claude-3-sonnet" STARTS-WITH? if 3.0 15.0 3.75 0.3 exit then
   a u s" claude-3-haiku" STARTS-WITH? if 0.25 1.25 0.3 0.03 exit then
   a u s" claude-2" STARTS-WITH? if 8.0 24.0 0.0 0.0 exit then
   0.0 0.0 0.0 0.0 ;

: U>F ( n -- r ) {: v:n :}
   v 32 rshift s>f 4294967296.0 f*
   v $FFFFFFFF and s>f f+ ;

: PRICED-COST ( -- r )
   MODEL-P @ MODEL-U @ MODEL-BASE PRICE-RATES
   {: ir:r or:r cr:r rr:r :}
   INPUT-N @ CREATE-N @ + READ-N @ + U>F 1000000.0 f/ ir f*
   CREATE-N @ U>F 1000000.0 f/ cr f* f+
   READ-N @ U>F 1000000.0 f/ rr f* f+
   OUTPUT-N @ U>F 1000000.0 f/ or f* f+ ;

: EVENT-COST ( -- r )
   HAS-COST @ 0<> if COST-EXPLICIT @ else PRICED-COST then ;

: EVENT-RESET ( ptr u8 -- ) {: base:ptr :}
   base TIMESTAMP-P ! base SESSION-P ! base MODEL-P !
   0 TIMESTAMP-U ! 0 SESSION-U ! 0 MODEL-U !
   0 INPUT-N ! 0 OUTPUT-N ! 0 CREATE-N ! 0 READ-N !
   0 HAS-INPUT ! 0 HAS-COST ! ;

1 constant F-TIMESTAMP
2 constant F-SESSION
3 constant F-MODEL
4 constant F-INPUT
5 constant F-OUTPUT
6 constant F-CREATE
7 constant F-READ
8 constant F-COST

: FIELD-CODE ( ptr u8 n -- n ) {: a:ptr u:n :}
   a u s" timestamp" STR= if F-TIMESTAMP exit then
   a u s" sessionId" STR= if F-SESSION exit then
   a u s" model" STR= if F-MODEL exit then
   a u s" input_tokens" STR= if F-INPUT exit then
   a u s" output_tokens" STR= if F-OUTPUT exit then
   a u s" cache_creation_input_tokens" STR= if F-CREATE exit then
   a u s" cache_read_input_tokens" STR= if F-READ exit then
   a u s" costUSD" STR= if F-COST exit then
   0 ;

: SCAN-CHAR ( ptr u8 n n n -- n ) {: a:ptr u:n at:n ch:n :}
   at begin dup u < if a over + c@ ch <> else FALSE-FLAG then while 1+ repeat ;

: SCAN-SPACE ( ptr u8 n n -- n ) {: a:ptr u:n at:n :}
   at begin dup u < if a over + c@ dup 32 = swap 9 = or else FALSE-FLAG then while 1+ repeat ;

: SCAN-U64 ( ptr u8 n n -- n ) {: a:ptr u:n at:n :}
   0 at begin dup u < if a over + c@ dup 48 >= swap 57 <= and else FALSE-FLAG then while
      swap 10 * over a + c@ 48 - + swap 1+
   repeat drop ;

: SCAN-COST-END ( ptr u8 n n -- n ) {: a:ptr u:n at:n :}
   at begin dup u < if
      a over + c@ {: c:n :}
      c 48 >= c 57 <= and c 46 = or c 45 = or c 101 = or c 69 = or
   else FALSE-FLAG then while 1+ repeat ;

: RECORD-STRING ( ptr u8 n n n -- n ) {: a:ptr u:n at:n field:n :}
   at u >= if at exit then
   a at + c@ 34 <> if at exit then
   a u at 1+ 34 SCAN-CHAR {: stop:n :}
   stop u >= if u exit then
   field F-TIMESTAMP = if a at 1+ + TIMESTAMP-P ! stop at 1+ - TIMESTAMP-U ! then
   field F-SESSION = if a at 1+ + SESSION-P ! stop at 1+ - SESSION-U ! then
   field F-MODEL = if a at 1+ + MODEL-P ! stop at 1+ - MODEL-U ! then
   stop 1+ ;

: RECORD-COST ( ptr u8 n n -- n ) {: a:ptr u:n at:n :}
   0 HAS-COST !
   a u at SCAN-COST-END {: stop:n :}
   a at + stop at - F64-TEXT:PARSE MATCH result
      ok OF COST-EXPLICIT ! 1 HAS-COST ! ENDOF
      err OF
         MATCH F64-TEXT:fault
         nonfinite OF
            a at + c@ 45 = if $FFF0000000000000 else $7FF0000000000000 then
            IEEE754:BITS>F64 COST-EXPLICIT ! 1 HAS-COST !
         ENDOF
         malformed OF ENDOF trailing OF ENDOF
         capacity OF ENDOF runtime OF ENDOF
         ;MATCH
      ENDOF
   ;MATCH
   stop ;

: RECORD-VALUE ( ptr u8 n n n -- n ) {: a:ptr u:n at:n field:n :}
   field F-TIMESTAMP = field F-SESSION = or field F-MODEL = or if
      a u at field RECORD-STRING exit
   then
   field F-INPUT = if 1 HAS-INPUT ! a u at SCAN-U64 INPUT-N ! at exit then
   field F-OUTPUT = if a u at SCAN-U64 OUTPUT-N ! at exit then
   field F-CREATE = if a u at SCAN-U64 CREATE-N ! at exit then
   field F-READ = if a u at SCAN-U64 READ-N ! at exit then
   field F-COST = if a u at RECORD-COST exit then
   at ;

: PARSE-JSON ( ptr u8 n -- ) {: a:ptr u:n :}
   0 SCAN-POS !
   begin SCAN-POS @ u < while
      a u SCAN-POS @ 34 SCAN-CHAR dup u >= if drop exit then
      1+ {: start:n :}
      a u start 34 SCAN-CHAR dup u >= if drop exit then {: stop:n :}
      a start + stop start - FIELD-CODE KEY-FIELD !
      a u stop 1+ SCAN-SPACE dup u >= if drop exit then {: colon:n :}
      a colon + c@ 58 = if
         a u colon 1+ SCAN-SPACE dup u >= if drop exit then
         {: value-at:n :}
         a u value-at KEY-FIELD @ RECORD-VALUE
      else stop 1+ then
      SCAN-POS !
   repeat ;

: DIGITS ( ptr u8 n n -- n ) {: a:ptr at:n count:n :}
   a at + c@ 45 = if -1 else 1 then {: sign:n :}
   a at + c@ dup 43 = swap 45 = or if 1 else 0 then {: start:n :}
   a at start + + c@ 95 = a at count 1- + + c@ 95 = or if
      0 TIME-VALID ! 0 exit
   then
   0 count start ?do
      a at i + + c@ dup 95 = if drop else
         dup 48 < over 57 > or if drop drop 0 TIME-VALID ! 0 unloop exit then
         48 - swap 10 * +
      then
   loop
   dup 0<> sign 0< and count 2 = and if drop 0 TIME-VALID ! 0 exit then
   sign * ;

create MONTH-DAYS 31 c, 28 c, 31 c, 30 c, 31 c, 30 c,
   31 c, 31 c, 30 c, 31 c, 30 c, 31 c,
variable DAY-ACC
variable YEAR-CURSOR
variable MONTH-CURSOR

: CURRENT-MONTH-DAYS ( -- n )
   MONTH-DAYS DATE-MONTH @ 1- + c@
   DATE-MONTH @ 2 = DATE-YEAR @ DATE:LEAP-YEAR? and if 1+ then ;

: CURRENT-YEAR-DAYS ( -- n )
   DATE-YEAR @ DATE:LEAP-YEAR? if 366 else 365 then ;

: EVENT-TIME ( -- n )
   TIMESTAMP-U @ 19 < if 0 exit then
   1 TIME-VALID !
   TIMESTAMP-P @ 0 4 DIGITS {: y:n :}
   TIMESTAMP-P @ 5 2 DIGITS {: m:n :}
   TIMESTAMP-P @ 8 2 DIGITS {: d:n :}
   TIMESTAMP-P @ 11 2 DIGITS {: hour:n :}
   TIMESTAMP-P @ 14 2 DIGITS {: minute:n :}
   TIMESTAMP-P @ 17 2 DIGITS {: second:n :}
   TIME-VALID @ 0= if 0 exit then
   \ Month 13 retains the source's overflow arithmetic; later months would
   \ index beyond its twelve-entry month table.
   m 13 > if 0 TIME-VALID ! 0 exit then
   0 DAY-ACC ! 1970 YEAR-CURSOR !
   begin YEAR-CURSOR @ y < while
      YEAR-CURSOR @ DATE:LEAP-YEAR? if 366 else 365 then DAY-ACC +!
      1 YEAR-CURSOR +!
   repeat
   1 MONTH-CURSOR !
   begin MONTH-CURSOR @ m < while
      MONTH-CURSOR @ 12 > if 0 exit then
      MONTH-DAYS MONTH-CURSOR @ 1- + c@ DAY-ACC +!
      MONTH-CURSOR @ 2 = y DATE:LEAP-YEAR? and if 1 DAY-ACC +! then
      1 MONTH-CURSOR +!
   repeat
   DAY-ACC @ d + 1- 86400 *
   hour 3600 * + minute 60 * + second + ;

\ The source calendar walks forward from 1970, even for negative epoch days.
\ That makes -1 format as 1970-01-00 and carries oversized days into 10000.
: FORMAT-SOURCE-DATE ( n -- ptr u8 n ) {: ts:n :}
   ts 86400 / ts 0 < ts 86400 mod 0<> and if 1- then DATE-REMAIN !
   1970 DATE-YEAR !
   begin CURRENT-YEAR-DAYS DATE-REMAIN @ <= while
      CURRENT-YEAR-DAYS negate DATE-REMAIN +! 1 DATE-YEAR +!
   repeat
   1 DATE-MONTH !
   begin DATE-MONTH @ 12 <= if
         CURRENT-MONTH-DAYS DATE-REMAIN @ <=
      else FALSE-FLAG then while
      CURRENT-MONTH-DAYS negate DATE-REMAIN +! 1 DATE-MONTH +!
   repeat
   DATE-YEAR @ 10000 >= if 49 DATE-BUF c! 1 else 0 then DATE-U !
   DATE-YEAR @ 4 DATE-BUF DATE-U @ DATE:WIDTH!
   4 DATE-U +!
   45 DATE-BUF DATE-U @ + c! 1 DATE-U +!
   DATE-MONTH @ 2 DATE-BUF DATE-U @ DATE:WIDTH! 2 DATE-U +!
   45 DATE-BUF DATE-U @ + c! 1 DATE-U +!
   DATE-REMAIN @ 1+ $FF and 2 DATE-BUF DATE-U @ DATE:WIDTH! 2 DATE-U +!
   DATE-BUF DATE-U @ ;

: POOL-ADD ( ptr u8 n -- n ) {: a:ptr u:n :}
   POOL-U @ {: off:n :}
   off u + STRING-POOL-RESERVE
   u 0 > if a off STRING-POOL u BYTE-COPY then
   off u + POOL-U !
   off ;

: POOL$ ( n n -- ptr u8 n ) {: off:n u:n :}
   off STRING-POOL u ;

: ROW-KEY$ ( n -- ptr u8 n ) {: idx:n :}
   idx ROW-KEY-OFF @ idx ROW-KEY-U @ POOL$ ;
: ROW-PROJECT$ ( n -- ptr u8 n ) {: idx:n :}
   idx ROW-PROJECT-OFF @ idx ROW-PROJECT-U @ POOL$ ;

: COPY-ROW-KEY ( ptr u8 n n -- ) {: a:ptr u:n idx:n :}
   a u POOL-ADD idx ROW-KEY-OFF !
   u idx ROW-KEY-U ! ;

: RESERVE-ROWS ( n -- ) {: count:n :}
   count ROW-KEY-OFF-RESERVE count ROW-KEY-U-RESERVE
   count ROW-PROJECT-OFF-RESERVE count ROW-PROJECT-U-RESERVE
   count ROW-IN-RESERVE count ROW-OUT-RESERVE
   count ROW-CREATE-RESERVE count ROW-READ-RESERVE
   count ROW-LAST-RESERVE count ROW-COST-RESERVE
   count ROW-ORDER-RESERVE count ROW-RANK-RESERVE
   count ROW-MODEL-HEAD-RESERVE count ROW-MODEL-TAIL-RESERVE
   count ROW-PROJECT-HEAD-RESERVE count ROW-PROJECT-TAIL-RESERVE
   count ROW-MODEL-SIZE-RESERVE count ROW-MODEL-CAP-RESERVE
   count ROW-PROJECT-SIZE-RESERVE count ROW-PROJECT-CAP-RESERVE ;

: SET$ ( n -- ptr u8 n ) {: idx:n :}
   idx SET-OFF @ idx SET-U @ POOL$ ;

$A0761D6478BD642F constant WY-SECRET-0
$E7037ED1A0B428DB constant WY-SECRET-1
$8EBC6AF09C88C6E3 constant WY-SECRET-2
$589965CC75374CC3 constant WY-SECRET-3
$FFFFFFFF constant WY-HALF
variable WY-STATE-0
variable WY-STATE-1
variable WY-STATE-2
variable WY-A
variable WY-B
variable WY-POS

: WY-MUL ( n n -- n n ) {: a:n b:n :}
   a WY-HALF and b WY-HALF and * {: p00:n :}
   a WY-HALF and b 32 rshift * {: p01:n :}
   a 32 rshift b WY-HALF and * {: p10:n :}
   a 32 rshift b 32 rshift * {: p11:n :}
   p00 32 rshift p01 WY-HALF and + p10 WY-HALF and + {: middle:n :}
   p00 WY-HALF and middle 32 lshift or
   p11 p01 32 rshift + p10 32 rshift + middle 32 rshift + ;

: WY-MIX ( n n -- n ) WY-MUL xor ;

: WY-READ ( ptr u8 n n -- n ) {: a:ptr offset:n width:n :}
   0 width 0 ?do
      a offset i + + c@ i 8 * lshift or
   loop ;

: WY-SMALL ( ptr u8 n -- ) {: a:ptr u:n :}
   u 4 >= if
      u 3 rshift 2 lshift {: quarter:n :}
      a 0 4 WY-READ 32 lshift a quarter 4 WY-READ or WY-A !
      a u 4 - 4 WY-READ 32 lshift
      a u 4 - quarter - 4 WY-READ or WY-B !
      exit
   then
   u 0 > if
      a c@ 16 lshift a u 1 rshift + c@ 8 lshift or
      a u 1- + c@ or WY-A !
   else 0 WY-A ! then
   0 WY-B ! ;

: WY-ROUND ( ptr u8 n -- ) {: a:ptr pos:n :}
   a pos 8 WY-READ WY-SECRET-1 xor
   a pos 8 + 8 WY-READ WY-STATE-0 @ xor WY-MIX WY-STATE-0 !
   a pos 16 + 8 WY-READ WY-SECRET-2 xor
   a pos 24 + 8 WY-READ WY-STATE-1 @ xor WY-MIX WY-STATE-1 !
   a pos 32 + 8 WY-READ WY-SECRET-3 xor
   a pos 40 + 8 WY-READ WY-STATE-2 @ xor WY-MIX WY-STATE-2 ! ;

: WY-HASH ( ptr u8 n -- n ) {: a:ptr u:n :}
   WY-SECRET-0 WY-SECRET-1 WY-MIX dup WY-STATE-0 !
   dup WY-STATE-1 ! WY-STATE-2 !
   u 16 <= if a u WY-SMALL else
      0 WY-POS !
      u 48 >= if
         begin WY-POS @ 48 + u < while
            a WY-POS @ WY-ROUND 48 WY-POS +!
         repeat
         WY-STATE-0 @ WY-STATE-1 @ xor WY-STATE-2 @ xor WY-STATE-0 !
      then
      begin WY-POS @ 16 + u < while
         a WY-POS @ 8 WY-READ WY-SECRET-1 xor
         a WY-POS @ 8 + 8 WY-READ WY-STATE-0 @ xor WY-MIX WY-STATE-0 !
         16 WY-POS +!
      repeat
      a u 16 - 8 WY-READ WY-A !
      a u 8 - 8 WY-READ WY-B !
   then
   WY-A @ WY-SECRET-1 xor
   WY-B @ WY-STATE-0 @ xor WY-MUL {: low:n high:n :}
   low WY-SECRET-0 xor u xor high WY-SECRET-1 xor WY-MIX ;

: MAP-CAP-NEXT ( n n -- n ) {: cap:n size:n :}
   \ Zig grows before lookup, even when the key is already present.
   cap 0= if 8 exit then
   size cap 80 * 100 / >= if cap 2 * else cap then ;

: ROW-SLOT ( ptr u8 n -- n ) {: a:ptr u:n :}
   a u WY-HASH ROW-MAP-CAP @ 1- and
   begin
      dup ROW-SLOTS @ {: row:n :}
      row -1 = if exit then
      row ROW-KEY$ a u STR= if exit then
      1+ ROW-MAP-CAP @ 1- and
   again ;

: ROW-GROW ( -- )
   ROW-MAP-CAP @ {: old:n :}
   old ROW-SLOTS-OLD-RESERVE
   old 0 ?do i ROW-SLOTS @ i ROW-SLOTS-OLD ! loop
   old 0= if 8 else old 2 * then dup ROW-MAP-CAP ! ROW-SLOTS-RESERVE
   ROW-MAP-CAP @ 0 ?do -1 i ROW-SLOTS ! loop
   old 0 ?do
      i ROW-SLOTS-OLD @ dup -1 <> if
         dup ROW-KEY$ ROW-SLOT ROW-SLOTS !
      else drop then
   loop ;

: SET-SLOT ( n n ptr u8 n -- n ) {: row:n kind:n a:ptr u:n :}
   a u WY-HASH row WY-SECRET-0 * xor kind xor SET-CAP @ 1- and
   begin
      dup SET-SLOTS @ {: entry:n :}
      entry -1 = if exit then
      entry SET-ROW @ row = entry SET-KIND @ kind = and if
         entry SET$ a u STR= if exit then
      then
      1+ SET-CAP @ 1- and
   again ;

: SET-GROW ( -- )
   SET-CAP @ {: old:n :}
   old SET-SLOTS-OLD-RESERVE
   old 0 ?do i SET-SLOTS @ i SET-SLOTS-OLD ! loop
   old 0= if 8 else old 2 * then dup SET-CAP ! SET-SLOTS-RESERVE
   SET-CAP @ 0 ?do -1 i SET-SLOTS ! loop
   old 0 ?do
      i SET-SLOTS-OLD @ dup -1 <> if
         dup {: entry:n :}
         entry SET-ROW @ entry SET-KIND @ entry SET$ SET-SLOT SET-SLOTS !
      else drop then
   loop ;

: SET-ADD ( n n ptr u8 n -- ) {: row:n kind:n a:ptr u:n :}
   kind 1 = if
      row ROW-MODEL-CAP @ row ROW-MODEL-SIZE @ MAP-CAP-NEXT
      row ROW-MODEL-CAP !
   else
      row ROW-PROJECT-CAP @ row ROW-PROJECT-SIZE @ MAP-CAP-NEXT
      row ROW-PROJECT-CAP !
   then
   SET-CAP @ SET-COUNT @ MAP-CAP-NEXT SET-CAP @ <> if SET-GROW then
   row kind a u SET-SLOT {: slot:n :}
   slot SET-SLOTS @ -1 <> if exit then
   SET-COUNT @ {: entry:n :}
   entry 1+ {: count:n :}
   count SET-ROW-RESERVE count SET-KIND-RESERVE count SET-NEXT-RESERVE
   count SET-OFF-RESERVE count SET-U-RESERVE
   row entry SET-ROW !
   kind entry SET-KIND !
   a u POOL-ADD entry SET-OFF !
   u entry SET-U !
   -1 entry SET-NEXT !
   kind 1 = if
      row ROW-MODEL-TAIL @ dup -1 <> if entry swap SET-NEXT !
      else drop entry row ROW-MODEL-HEAD ! then
      entry row ROW-MODEL-TAIL !
      1 row ROW-MODEL-SIZE +!
   else
      row ROW-PROJECT-TAIL @ dup -1 <> if entry swap SET-NEXT !
      else drop entry row ROW-PROJECT-HEAD ! then
      entry row ROW-PROJECT-TAIL !
      1 row ROW-PROJECT-SIZE +!
   then
   entry slot SET-SLOTS !
   count SET-COUNT ! ;

: FIND-ROW ( ptr u8 n -- n ) {: a:ptr u:n :}
   \ Grow before lookup, including duplicates, just like Zig's StringHashMap.
   ROW-MAP-CAP @ ROW-COUNT @ MAP-CAP-NEXT ROW-MAP-CAP @ <> if ROW-GROW then
   a u ROW-SLOT {: slot:n :}
   slot ROW-SLOTS @ dup -1 <> if exit then drop
   ROW-COUNT @ 1+ RESERVE-ROWS
   a u ROW-COUNT @ COPY-ROW-KEY
   0 ROW-COUNT @ ROW-IN !
   0 ROW-COUNT @ ROW-OUT !
   0 ROW-COUNT @ ROW-CREATE !
   0 ROW-COUNT @ ROW-READ !
   0 ROW-COUNT @ ROW-LAST !
   0 ROW-COUNT @ ROW-PROJECT-U !
   0 ROW-COUNT @ ROW-MODEL-SIZE !
   0 ROW-COUNT @ ROW-MODEL-CAP !
   0 ROW-COUNT @ ROW-PROJECT-SIZE !
   0 ROW-COUNT @ ROW-PROJECT-CAP !
   -1 ROW-COUNT @ ROW-MODEL-HEAD !
   -1 ROW-COUNT @ ROW-MODEL-TAIL !
   -1 ROW-COUNT @ ROW-PROJECT-HEAD !
   -1 ROW-COUNT @ ROW-PROJECT-TAIL !
   0.0 ROW-COUNT @ ROW-COST !
   ROW-COUNT @ slot ROW-SLOTS !
   ROW-COUNT @ dup 1+ ROW-COUNT ! ;

: ADD-ROW ( n n -- ) {: idx:n ts:n :}
   INPUT-N @ idx ROW-IN +!
   OUTPUT-N @ idx ROW-OUT +!
   CREATE-N @ idx ROW-CREATE +!
   READ-N @ idx ROW-READ +!
   ts idx ROW-LAST @ max idx ROW-LAST !
   idx ROW-COST @ EVENT-COST f+ idx ROW-COST ! ;

: EVENT-KEY ( n -- ptr u8 n ) {: ts:n :}
   MODE @ SESSIONS = if SESSION-P @ SESSION-U @ exit then
   ts TIMEZONE-MIN @ 60 * + FORMAT-SOURCE-DATE
   MODE @ MONTHLY = if drop DATE-U @ 3 - then ;

: ACCEPT-EVENT ( -- )
   HAS-INPUT @ 0= if exit then
   EVENT-TIME {: ts:n :}
   ts 0= if exit then
   \ The source's forward date walk supports day zero at -86400. Earlier
   \ adjusted dates have a negative day that cannot be rendered as u8.
   MODE @ SESSIONS <> if
      ts TIMEZONE-MIN @ 60 * + -86400 < if exit then
   then
   ts EVENT-KEY FIND-ROW {: idx:n :}
   idx 1 MODEL-P @ MODEL-U @ SET-ADD
   MODE @ SESSIONS <> if idx 2 PROJECT-P @ PROJECT-U @ SET-ADD then
   MODE @ SESSIONS = if
      idx ROW-PROJECT-U @ 0= if
         PROJECT-P @ PROJECT-U @ POOL-ADD idx ROW-PROJECT-OFF !
         PROJECT-U @ idx ROW-PROJECT-U !
      then
   then
   idx ts ADD-ROW ;

: PARSE-LINE ( ptr u8 n -- ) {: a:ptr u:n :}
   u 50 < if exit then
   a EVENT-RESET
   a u PARSE-JSON
   ACCEPT-EVENT ;

: PARSE-FILE-CONTENT ( n -- ) {: u:n :}
   0 begin dup u < while
      {: at:n :}
      at begin dup u < if 0 FILE-BUF over + c@ LF <> else FALSE-FLAG then while 1+ repeat
      {: stop:n :}
      0 FILE-BUF at + stop at - PARSE-LINE
      stop 1+ 
   repeat drop ;

: FILE-PROJECT ( ptr u8 n -- ) {: a:ptr u:n :}
   PROJECTS-U @ 1+ {: at:n :}
   at begin dup u < if a over + c@ 47 <> else FALSE-FLAG then while 1+ repeat
   at - {: len:n :}
   a at + PROJECT-P !
   len PROJECT-U ! ;

: VISIT-FILE ( ptr u8 n -- ) {: a:ptr u:n :}
   a u s" .jsonl" ENDS-WITH? 0= if exit then
   a u FILE-PROJECT
   a u FS-PATHZ open-rd dup 0 < if drop exit then FILE-FD !
   0 FILE-U !
   65536 dup FILE-ALLOC ! FILE-BUF-RESERVE
   begin
      FILE-U @ FILE-CAP = if
         FILE-FD @ FILE-PROBE 1 read dup 0 > if
            drop FILE-FD @ close exit
         then
         dup 0 < if drop FILE-FD @ close exit then drop
         FILE-FD @ close FILE-U @ PARSE-FILE-CONTENT exit
      then
      FILE-U @ FILE-ALLOC @ >= if
         FILE-U @ 2 * 65536 max FILE-CAP min dup FILE-ALLOC ! FILE-BUF-RESERVE
      then
      FILE-FD @ 0 FILE-BUF FILE-U @ + FILE-ALLOC @ FILE-U @ - read FILE-READ !
      FILE-READ @ 0 < if FILE-FD @ close exit then
      FILE-READ @ 0= if FILE-FD @ close FILE-U @ PARSE-FILE-CONTENT exit then
      FILE-READ @ FILE-U +!
   again ;

: VISIT-FILE-TRY ( ptr u8 n -- ptr u8 n ) 2dup VISIT-FILE ;

defer WALK-CURRENT ( -- )

: WALK-ENTRY ( ptr u8 n -- ) {: name:ptr nu:n :}
   PATH-U @ {: old:n :}
   old 0 > if PATH-BUF old 1- + c@ 47 = else FALSE-FLAG then
   if old else 47 PATH-BUF old + c! old 1+ then {: next:n :}
   next nu + FS-PATH-CAP > if exit then
   name PATH-BUF next + nu BYTE-COPY
   next nu + PATH-U !
   PATH-BUF PATH-U @ SYMLINK? 0= if
      PATH-BUF PATH-U @ FILE? if
         PATH-BUF PATH-U @ [: VISIT-FILE-TRY ;] catch drop 2drop
      else
         PATH-BUF PATH-U @ DIR? if WALK-CURRENT then
      then
   then
   old PATH-U ! ;

: WALK-ITER ( -- ) PATH-BUF PATH-U @ [: WALK-ENTRY ;] FS-LIST:EACH ;
: INSTALL-WALK ( -- ) [: WALK-ITER ;] is WALK-CURRENT ;

: VISIT-DIR ( ptr u8 n -- ) {: a:ptr u:n :}
   a u s" projects" PATH-BUF JOIN-PATH dup PROJECTS-U ! PATH-U !
   PATH-BUF PATH-U @ DIR? if WALK-CURRENT then ;

: VISIT-DIR-TRY ( ptr u8 n -- ptr u8 n ) 2dup VISIT-DIR ;

: COLLECT ( -- )
   0 ROW-COUNT ! 0 POOL-U ! 0 SET-COUNT !
   DIR-COUNT @ 0 ?do
      i DIR-A @ i DIR-U @ [: VISIT-DIR-TRY ;] catch drop 2drop
   loop ;

: BYTE-LESS? ( ptr u8 n ptr u8 n -- bool ) {: a:ptr u:n b:ptr v:n :}
   u v min 0 ?do
      a i + c@ b i + c@ <> if a i + c@ b i + c@ < unloop exit then
   loop
   u v < ;

: BEFORE? ( n n -- bool ) {: x:n y:n :}
   MODE @ SESSIONS = if x ROW-LAST @ y ROW-LAST @ > exit then
   x ROW-KEY$ y ROW-KEY$ STR= if FALSE-FLAG exit then
   y ROW-KEY$ x ROW-KEY$ BYTE-LESS? ;

: RAW ( ptr u8 n -- ) OUT ;
: QUOTE ( -- ) QUOTE-BYTE 1 OUT ;
: KEY ( ptr u8 n -- ) QUOTE OUT QUOTE COLON-BYTE 1 OUT ;
: U64-DIV10 ( n -- n n ) {: v:n :}
   v 32 rshift $FFFFFFFF and 10 /mod {: hr:n hq:n :}
   hr 4294967296 * v $FFFFFFFF and + 10 /mod {: lr:n lq:n :}
   hq 32 lshift lq or lr ;
: U$ ( n -- ptr u8 n )
   20 U64-INDEX !
   begin U64-DIV10 {: q:n d:n :}
      U64-INDEX @ 1- dup U64-INDEX ! U64-BUF + d 48 + swap c!
      q 0= if U64-BUF U64-INDEX @ + 20 U64-INDEX @ - exit then
      q
   again ;
: U ( n -- ) U$ OUT ;
: STR ( ptr u8 n -- ) QUOTE OUT QUOTE ;

: TEXT-ADD ( ptr u8 n -- ) {: a:ptr u:n :}
   TEXT-U @ u + TEXT-BUF-RESERVE
   u 0 > if a TEXT-U @ TEXT-BUF u BYTE-COPY then
   TEXT-U @ u + TEXT-U ! ;
: TEXT-CHAR ( n -- ) {: c:n :}
   TEXT-U @ 1+ TEXT-BUF-RESERVE
   c TEXT-U @ TEXT-BUF c!
   TEXT-U @ 1+ TEXT-U ! ;
: TEXT$ ( -- ptr u8 n )
   TEXT-U @ 0= if LF-BYTE 0 exit then
   0 TEXT-BUF TEXT-U @ ;
: TEXT-NUM ( n -- ) U$ TEXT-ADD ;
: TEXT-RESET ( -- ) 0 TEXT-U ! ;

: U64-DIV ( n n -- n n ) {: v:n divisor:n :}
   v 32 rshift $FFFFFFFF and divisor /mod {: hr:n hq:n :}
   hr 4294967296 * v $FFFFFFFF and + divisor /mod {: lr:n lq:n :}
   hq 32 lshift lq or lr ;

: U-LESS? ( n n -- bool ) {: a:n b:n :}
   a $8000000000000000 xor b $8000000000000000 xor < ;

: MONEY-DIGIT ( ptr u8 n n -- n ) {: a:ptr len:n at:n :}
   at len < if a at + c@ 48 - else 0 then ;

: MONEY-CARRY-ONE ( n n -- bool ) {: start:n dot:n :}
   dot 1- MONEY-POS !
   begin MONEY-POS @ start >= while
      DECIMAL-BUF MONEY-POS @ + c@ 57 = if
         48 DECIMAL-BUF MONEY-POS @ + c!
         -1 MONEY-POS +!
      else
         DECIMAL-BUF MONEY-POS @ + dup c@ 1+ swap c!
         FALSE-FLAG exit
      then
   repeat 0 0= ;

: TEXT-TOKENS ( n -- ) {: v:n :}
   v 1000000000 U-LESS? 0= if 1000000000 s" B" else
   v 1000000 U-LESS? 0= if 1000000 s" M" else
   v 1000 U-LESS? 0= if 1000 s" K" else v TEXT-NUM exit then then then
   {: scale:n suffix:ptr su:n :}
   v U>F scale U>F f/
   DECIMAL-BUF F64-TEXT:MAX-BYTES F64-TEXT:FORMAT MATCH result
      ok OF ENDOF err OF drop CAPACITY-FAIL ENDOF
   ;MATCH
   {: len:n :}
   0 begin dup len < if DECIMAL-BUF over + c@ 46 <> else FALSE-FLAG then while 1+ repeat {: dot:n :}
   DECIMAL-BUF len dot 1+ MONEY-DIGIT {: first:n :}
   DECIMAL-BUF len dot 2 + MONEY-DIGIT {: second:n :}
   first second 5 >= if 1+ then {: digit:n :}
   digit 10 >= if 0 dot MONEY-CARRY-ONE else FALSE-FLAG then {: overflow:bool :}
   dot overflow if 1+ then 2 + su + 32 > if s" ?" TEXT-ADD exit then
   overflow if 49 TEXT-CHAR then
   DECIMAL-BUF dot TEXT-ADD
   46 TEXT-CHAR digit 10 mod 48 + TEXT-CHAR
   suffix su TEXT-ADD ;

: TEXT-COST-FIXED ( r n n -- ) {: value:r places:n suffix:n :}
   value DECIMAL-BUF F64-TEXT:MAX-BYTES F64-TEXT:FORMAT MATCH result
      ok OF ENDOF err OF drop CAPACITY-FAIL ENDOF
   ;MATCH {: len:n :}
   DECIMAL-BUF c@ 45 = if 1 else 0 then {: start:n :}
   start begin dup len < if DECIMAL-BUF over + c@ 46 <> else FALSE-FLAG then while 1+ repeat {: dot:n :}
   DECIMAL-BUF len dot 1+ MONEY-DIGIT {: first:n :}
   DECIMAL-BUF len dot 2 + MONEY-DIGIT {: second:n :}
   places 1 = if first second 5 >= if 1+ then else first 5 >= if 10 else 0 then then {: digit:n :}
   digit 10 >= if start dot MONEY-CARRY-ONE else FALSE-FLAG then {: overflow:bool :}
   1 start + dot start - + overflow if 1+ then
   places 1 = if 2 + then suffix 0<> if 1+ then {: width:n :}
   width 32 > if s" ?" TEXT-ADD exit then
   36 TEXT-CHAR
   start 0<> if 45 TEXT-CHAR then
   overflow if 49 TEXT-CHAR then
   DECIMAL-BUF start + dot start - TEXT-ADD
   places 1 = if 46 TEXT-CHAR digit 10 mod 48 + TEXT-CHAR then
   suffix 0<> if suffix TEXT-CHAR then ;

: TEXT-COST ( r -- ) {: value:r :}
   value IEEE754:F64>BITS {: bits:n :}
   bits $7FF0000000000000 and $7FF0000000000000 = if
      36 TEXT-CHAR
      bits $000FFFFFFFFFFFFF and 0<> if s" nan" TEXT-ADD exit then
      bits 0< if s" -inf" TEXT-ADD exit then
      s" infM" TEXT-ADD exit
   then
   value 1000000.0 f>= if
      value 1000000.0 f/ 1 77 TEXT-COST-FIXED exit
   then
   value -9000000000000000000.0 f< if value 0 0 TEXT-COST-FIXED exit then
   value 1000.0 f>= if
      value 1000.0 f/ 0 75 TEXT-COST-FIXED exit
   then
   value 0 0 TEXT-COST-FIXED ;

\ Zig's Ryu shortest decimal chooses an even last digit at a shortest-decimal
\ midpoint. F64-TEXT chooses away from zero. At these binary64 spacings the
\ two shortest spellings straddle a cent boundary, so correct that bounded
\ difference before emitting the two decimal places.
: MONEY-RYU-TIE ( r n -- n ) {: value:r cents:n :}
   value IEEE754:F64>BITS $7FFFFFFFFFFFFFFF and 52 rshift 1023 - {: exponent:n :}
   exponent 46 = exponent 47 = or if
      value fabs dup f>s s>f f- {: fraction:r :}
      fraction 0.125 f= if 12 exit then
      fraction 0.625 f= if 62 exit then
   then
   exponent 49 = exponent 50 = or if
      value fabs dup f>s s>f f- 0.25 f= if 20 exit then
   then
   cents ;

: MONEY-FRACTION ( n -- ) {: fraction:n :}
   fraction 10 / 48 + MONEY-BUF c!
   fraction 10 mod 48 + MONEY-BUF 1+ c!
   MONEY-BUF 2 RAW ;

\ Below 2^43, binary64 spacing is less than .001. A half-cent decimal's
\ nearest float therefore has that unique shortest three-decimal spelling.
\ Comparing against the rounded half-cent threshold preserves Zig's decimal
\ tie rounding, including values such as 1.005 whose binary value is lower.
: MONEY-SMALL ( r -- ) {: value:r :}
   value IEEE754:F64>BITS 0< if s" -" RAW then
   value fabs {: magnitude:r :}
   magnitude 100.0 f* f>s {: base:n :}
   magnitude base s>f 0.5 f+ 100.0 f/ f>=
   if base 1+ else base then {: cents:n :}
   cents 100 / U s" ." RAW cents 100 mod MONEY-FRACTION ;

: MONEY ( r -- )
   {: value:r :}
   value IEEE754:F64>BITS {: bits:n :}
   bits $7FF0000000000000 and $7FF0000000000000 = if
      bits $000FFFFFFFFFFFFF and 0<> if s" nan" RAW exit then
      bits 0< if s" -inf" RAW else s" inf" RAW then exit
   then
   value fabs 8796093022208.0 f< if value MONEY-SMALL exit then
   value
   DECIMAL-BUF F64-TEXT:MAX-BYTES F64-TEXT:FORMAT MATCH result
      ok OF ENDOF err OF drop CAPACITY-FAIL ENDOF
   ;MATCH {: len:n :}
   DECIMAL-BUF c@ 45 = if s" -" RAW 1 else 0 then {: start:n :}
   start begin dup len < if DECIMAL-BUF over + c@ 46 <> else FALSE-FLAG then while 1+ repeat {: dot:n :}
   DECIMAL-BUF len dot 1+ MONEY-DIGIT 10 *
   DECIMAL-BUF len dot 2 + MONEY-DIGIT +
   DECIMAL-BUF len dot 3 + MONEY-DIGIT 5 >= if 1+ then
   value swap MONEY-RYU-TIE {: cents:n :}
   cents 100 >= if
      start dot MONEY-CARRY-ONE if s" 1" RAW then
   then
   DECIMAL-BUF start + dot start - RAW
   s" ." RAW
   cents 100 mod MONEY-FRACTION ;

: ROW-TOTAL-TOKENS ( n -- n ) {: idx:n :}
   idx ROW-IN @ idx ROW-OUT @ + idx ROW-CREATE @ + idx ROW-READ @ + ;

: ROW-JSON ( n -- ) {: idx:n :}
   s" {" RAW
   MODE @ SESSIONS = if
      s" session_id" KEY idx ROW-KEY$ STR s" ," RAW
      s" project" KEY idx ROW-PROJECT$ STR s" ," RAW
   else
      s" key" KEY idx ROW-KEY$ STR s" ," RAW
   then
   s" input_tokens" KEY idx ROW-IN @ U s" ," RAW
   s" output_tokens" KEY idx ROW-OUT @ U s" ," RAW
   s" total_tokens" KEY idx ROW-TOTAL-TOKENS U s" ," RAW
   s" cost_usd" KEY idx ROW-COST @ MONEY
   s" }" RAW ;

: SUM-COLUMN ( n -- n ) {: col:n :}
   0 ROW-COUNT @ 0 ?do
      col 0 = if i ROW-IN @ + then
      col 1 = if i ROW-OUT @ + then
      col 2 = if i ROW-CREATE @ + then
      col 3 = if i ROW-READ @ + then
   loop ;

: SUM-COST ( -- r )
   0.0 ROW-COUNT @ 0 ?do i ROW-ORDER @ ROW-COST @ f+ loop ;

: TOTALS-JSON ( n -- ) {: idx:n :}
   s" {" RAW
   s" input_tokens" KEY idx 0 < if 0 SUM-COLUMN else idx ROW-IN @ then U s" ," RAW
   s" output_tokens" KEY idx 0 < if 1 SUM-COLUMN else idx ROW-OUT @ then U s" ," RAW
   idx 0 < if
      0 SUM-COLUMN 1 SUM-COLUMN + 2 SUM-COLUMN + 3 SUM-COLUMN +
   else idx ROW-TOTAL-TOKENS then
   s" total_tokens" KEY U s" ," RAW
   s" cost_usd" KEY idx 0 < if SUM-COST else idx ROW-COST @ then MONEY
   s" }" RAW ;

: KIND$ ( -- ptr u8 n )
   MODE @ MONTHLY = if s" monthly" exit then
   MODE @ SESSIONS = if s" sessions" exit then
   s" daily" ;

DYNAMIC-BUFFER HASH-SLOTS n
DYNAMIC-BUFFER HASH-OLD n
variable HASH-CAP
variable HASH-SIZE
variable ROW-POS

: ORDER-BEFORE? ( n n -- bool ) {: x:n y:n :}
   x y BEFORE? if true exit then
   y x BEFORE? if false exit then
   x ROW-RANK @ y ROW-RANK @ < ;

: SORT-ROWS ( -- )
   ROW-COUNT @ 0= if exit then
   0 ROW-POS !
   ROW-MAP-CAP @ 0 ?do
      i ROW-SLOTS @ dup -1 <> if
         ROW-POS @ over ROW-RANK !
         ROW-POS @ ROW-ORDER ! 1 ROW-POS +!
      else drop then
   loop
   \ A hash-slot rank makes the library heapsort preserve the source's tie order.
   0 ROW-ORDER ROW-COUNT @ [: ORDER-BEFORE? ;] SORT:SORT! ;

: HASH-INSERT ( n -- ) {: set-index:n :}
   set-index SET$ WY-HASH HASH-CAP @ 1- and {: start:n :}
   start begin dup HASH-SLOTS @ -1 <> while
      1+ HASH-CAP @ 1- and
   repeat
   set-index swap HASH-SLOTS !
   1 HASH-SIZE +! ;

: HASH-GROW ( -- )
   HASH-CAP @ {: old:n :}
   old HASH-OLD-RESERVE
   old 0 ?do i HASH-SLOTS @ i HASH-OLD ! loop
   old 0= if 8 else old 2 * then dup HASH-CAP ! HASH-SLOTS-RESERVE
   HASH-CAP @ 0 ?do -1 i HASH-SLOTS ! loop
   0 HASH-SIZE !
   old 0 ?do i HASH-OLD @ dup -1 <> if HASH-INSERT else drop then loop ;

: HASH-BUILD ( n n -- ) {: row:n kind:n :}
   0 HASH-CAP ! 0 HASH-SIZE !
   kind 1 = if row ROW-MODEL-HEAD @ else row ROW-PROJECT-HEAD @ then
   begin dup -1 <> while
      {: entry:n :}
      HASH-CAP @ 0= if HASH-GROW else
         HASH-SIZE @ HASH-CAP @ 80 * 100 / >= if HASH-GROW then
      then
      entry HASH-INSERT
      entry SET-NEXT @
   repeat drop
   \ Rehash through the capacity reached by all puts, including duplicates.
   kind 1 = if row ROW-MODEL-CAP @ else row ROW-PROJECT-CAP @ then
   begin HASH-CAP @ over < while HASH-GROW repeat drop ;

create ANSI-RESET 27 c, 91 c, 48 c, 109 c,
create ANSI-BOLD 27 c, 91 c, 49 c, 109 c,
create ANSI-DIM 27 c, 91 c, 50 c, 109 c,
create ANSI-CYAN 27 c, 91 c, 51 c, 54 c, 109 c,
create ANSI-YELLOW 27 c, 91 c, 51 c, 51 c, 109 c,
7 TYPED-BUFFER WIDTH n
variable SET-SCAN-COUNT
variable SET-SCAN-FIRST

: SHORT-PROJECT ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   a u s" -Users-" STARTS-WITH? if
      a 7 + u 7 - {: rest:ptr ru:n :}
      0 begin dup ru < if rest over + c@ 45 <> else FALSE-FLAG then while 1+ repeat
      dup ru >= if drop rest ru exit then 1+ {: at:n :}
      at begin dup ru < if rest over + c@ 45 <> else FALSE-FLAG then while 1+ repeat
      dup ru >= if drop rest at + ru at - exit then
      1+ rest swap + rest ru + over - exit
   then
   a u s" -private-" STARTS-WITH? if
      u begin dup 0 > while
         1- dup a + c@ 45 = if
            1+ dup u < if a over + u rot - exit then drop a u exit
         then
      repeat drop
   then
   a u ;

: SHORT-MODEL ( ptr u8 n -- ptr u8 n ) {: a:ptr u:n :}
   a u s" claude-" STARTS-WITH? 0= if a u exit then
   a 7 + u 7 - {: rest:ptr ru:n :}
   ru 9 > if
      rest ru 9 - + c@ 45 = if
         0 0= 8 0 ?do
            rest ru 8 - i + + c@ dup 48 < swap 57 > or if drop FALSE-FLAG leave then
         loop
         if rest ru 9 - exit then
      then
   then
   rest ru ;

: TEXT-PROJECTS ( n -- ) {: row:n :}
   row 2 HASH-BUILD
   HASH-SIZE @ 0= if s" -" TEXT-ADD exit then
   HASH-CAP @ 0 ?do
      i HASH-SLOTS @ dup -1 <> if
         SET$ SHORT-PROJECT TEXT-ADD leave
      else drop then
   loop
   HASH-SIZE @ 1 > if
      s" , +" TEXT-ADD HASH-SIZE @ 1- TEXT-NUM s"  more" TEXT-ADD
   then ;

: TEXT-MODELS ( n -- ) {: row:n :}
   row 1 HASH-BUILD
   0 SET-SCAN-COUNT !
   HASH-CAP @ 0 ?do
      i HASH-SLOTS @ dup -1 <> if
         SET$ {: model:ptr mu:n :}
         mu 0 > model mu s" <synthetic>" STR= 0= and if
            SET-SCAN-COUNT @ 0 > if s" , " TEXT-ADD then
            model mu SHORT-MODEL TEXT-ADD
            1 SET-SCAN-COUNT +!
         then
      else drop then
   loop
   SET-SCAN-COUNT @ 0= if s" -" TEXT-ADD then ;

: HEADER$ ( n -- ptr u8 n ) {: col:n :}
   MODE @ SESSIONS = if
      col 0 = if s" Session" exit then
      col 1 = if s" Project" exit then
      col 2 = if s" In" exit then
      col 3 = if s" Out" exit then
      col 4 = if s" Total" exit then
      col 5 = if s" Cost" exit then
      s" Models" exit
   then
   col 0 = if s" Period" exit then
   col 1 = if s" In" exit then
   col 2 = if s" Out" exit then
   col 3 = if s" Total" exit then
   col 4 = if s" Cost" exit then
   col 5 = if s" Projects" exit then
   s" Models" ;

: FOOTER-CELL ( n -- ) {: col:n :}
   MODE @ SESSIONS = if
      col 0 = if s" TOTAL" TEXT-ADD exit then
      col 1 = col 6 = or if exit then
      col 2 -
   else
      col 0 = if s" Total" TEXT-ADD exit then
      col 5 >= if exit then
      col 1-
   then
   {: n:n :}
   n 0 = if 0 SUM-COLUMN TEXT-TOKENS exit then
   n 1 = if 1 SUM-COLUMN TEXT-TOKENS exit then
   n 2 = if 0 SUM-COLUMN 1 SUM-COLUMN + 2 SUM-COLUMN + 3 SUM-COLUMN + TEXT-TOKENS exit then
   SUM-COST TEXT-COST ;

: TEXT-FOOTER ( n -- ) {: col:n :}
   MODE @ SESSIONS = if col 1 = col 6 = or else col 5 >= then if exit then
   col FOOTER-CELL
   TEXT-U @ col 0 = if 13 else 9 then + 32 > if exit then
   TEXT-RESET
   ANSI-YELLOW 5 TEXT-ADD
   col 0 = if ANSI-BOLD 4 TEXT-ADD then
   col FOOTER-CELL
   ANSI-RESET 4 TEXT-ADD ;

: TRUNCATE ( ptr u8 n n -- ptr u8 n ) {: a:ptr u:n limit:n :}
   a u limit min ;

: TEXT-ROW-PERIOD ( n n -- ) {: row:n col:n :}
   col 0 = if row ROW-KEY$ TEXT-ADD exit then
   col 1 = if row ROW-IN @ TEXT-TOKENS exit then
   col 2 = if row ROW-OUT @ TEXT-TOKENS exit then
   col 3 = if row ROW-TOTAL-TOKENS TEXT-TOKENS exit then
   col 4 = if row ROW-COST @ TEXT-COST exit then
   col 5 = if row TEXT-PROJECTS exit then
   row TEXT-MODELS ;

: TEXT-ROW-SESSION ( n n -- ) {: row:n col:n :}
   col 0 = if row ROW-KEY$ 12 TRUNCATE TEXT-ADD exit then
   col 1 = if row ROW-PROJECT$ 16 TRUNCATE TEXT-ADD exit then
   col 2 = if row ROW-IN @ TEXT-TOKENS exit then
   col 3 = if row ROW-OUT @ TEXT-TOKENS exit then
   col 4 = if row ROW-TOTAL-TOKENS TEXT-TOKENS exit then
   col 5 = if row ROW-COST @ TEXT-COST exit then
   row TEXT-MODELS ;

: CELL$ ( n n -- ptr u8 n ) {: row:n col:n :}
   row -2 = if col HEADER$ exit then
   TEXT-RESET
   row -1 = if col TEXT-FOOTER else
      MODE @ SESSIONS = if row col TEXT-ROW-SESSION else row col TEXT-ROW-PERIOD then
   then
   TEXT$ ;

: VISIBLE-LEN ( ptr u8 n -- n ) {: a:ptr u:n :}
   0 0 u 0 ?do
      a i + c@ {: c:n :}
      c 27 = if drop 1 else
         dup 0<> if c 109 = if drop 0 then else swap 1+ swap then
      then
   loop drop ;

: SPACES ( n -- ) 0 ?do s"  " OUT loop ;
: HORIZ ( n -- ) 0 ?do s" ─" OUT loop ;

: TABLE-BORDER ( n -- ) {: kind:n :}
   kind 0 = if s" ┌" OUT else kind 1 = if s" ├" OUT else s" └" OUT then then
   7 0 ?do
      i WIDTH @ 2 + HORIZ
      i 6 < if
         kind 0 = if s" ┬" OUT else kind 1 = if s" ┼" OUT else s" ┴" OUT then then
      else
         kind 0 = if s" ┐" OUT else kind 1 = if s" ┤" OUT else s" ┘" OUT then then
      then
   loop OUT-LF ;

: TABLE-CELL ( n n -- ) {: row:n col:n :}
   s"  " OUT
   row -2 = if ANSI-CYAN 5 OUT ANSI-BOLD 4 OUT then
   row col CELL$ {: a:ptr u:n :}
   a u OUT
   row -2 = if ANSI-RESET 4 OUT then
   col WIDTH @ a u VISIBLE-LEN - 1+ SPACES
   s" │" OUT ;

: TABLE-ROW ( n -- ) {: row:n :}
   s" │" OUT
   7 0 ?do row i TABLE-CELL loop
   OUT-LF ;

: TABLE-WIDTHS ( -- )
   7 0 ?do -2 i CELL$ VISIBLE-LEN i WIDTH ! loop
   ROW-COUNT @ 0 ?do
      7 0 ?do j ROW-ORDER @ i CELL$ VISIBLE-LEN i WIDTH @ max i WIDTH ! loop
   loop
   7 0 ?do -1 i CELL$ VISIBLE-LEN i WIDTH @ max i WIDTH ! loop ;

: REPORT-TABLE ( -- )
   ANSI-BOLD 4 OUT
   MODE @ SESSIONS = if s" Session usage" OUT else
      MODE @ MONTHLY = if s" Monthly usage" OUT else s" Daily usage" OUT then
   then
   ANSI-RESET 4 OUT OUT-LF
   TABLE-WIDTHS
   0 TABLE-BORDER -2 TABLE-ROW 1 TABLE-BORDER
   ROW-COUNT @ 0 ?do i ROW-ORDER @ TABLE-ROW loop
   1 TABLE-BORDER -1 TABLE-ROW 2 TABLE-BORDER ;

: REPORT-PERIOD ( -- )
   SORT-ROWS
   JSON-FLAG @ 0= if REPORT-TABLE exit then
   s" {" RAW s" kind" KEY KIND$ STR s" ," RAW
   s" rows" KEY s" [" RAW
   ROW-COUNT @ 0 ?do
      i 0 > if s" ," RAW then
      i ROW-ORDER @ ROW-JSON
   loop
   s" ]," RAW s" totals" KEY -1 TOTALS-JSON s" }" RAW LF-BYTE 1 RAW ;

: STATUS-TOTALS ( n -- ) {: idx:n :}
   s" {" RAW
   s" input_tokens" KEY idx ROW-IN @ U s" ," RAW
   s" output_tokens" KEY idx ROW-OUT @ U s" ," RAW
   s" cache_creation_tokens" KEY idx ROW-CREATE @ U s" ," RAW
   s" cache_read_tokens" KEY idx ROW-READ @ U s" ," RAW
   s" total_tokens" KEY idx ROW-TOTAL-TOKENS U s" ," RAW
   s" cost_usd" KEY idx ROW-COST @ MONEY
   s" }" RAW ;

: STATUS-DIM ( ptr u8 n -- ) {: a:ptr u:n :}
   ANSI-DIM 4 OUT a u OUT ANSI-RESET 4 OUT ;

: STATUS-SEP ( ptr u8 n -- )
   s"  " OUT s" |" STATUS-DIM s"  " OUT STATUS-DIM s"  " OUT ;

: STATUS-NUM ( n -- ) TEXT-RESET TEXT-TOKENS TEXT$ OUT ;

: REPORT-STATUS-TEXT ( -- )
   ROW-COUNT @ 0= if s" No data" OUT OUT-LF exit then
   STATUS-INDEX @ {: row:n :}
   ANSI-CYAN 5 OUT ANSI-BOLD 4 OUT row ROW-KEY$ OUT ANSI-RESET 4 OUT
   s" in" STATUS-SEP row ROW-IN @ STATUS-NUM
   s" out" STATUS-SEP row ROW-OUT @ STATUS-NUM
   s" c/w" STATUS-SEP row ROW-CREATE @ STATUS-NUM
   s" c/r" STATUS-SEP row ROW-READ @ STATUS-NUM
   s" total" STATUS-SEP row ROW-TOTAL-TOKENS STATUS-NUM
   s"  " OUT s" |" STATUS-DIM s"  " OUT
   TEXT-RESET row ROW-COST @ TEXT-COST
   TEXT-U @ 13 + 32 <= if ANSI-YELLOW 5 OUT ANSI-BOLD 4 OUT then
   TEXT$ OUT
   TEXT-U @ 13 + 32 <= if ANSI-RESET 4 OUT then
   OUT-LF ;

: REPORT-STATUS ( -- )
   ROW-COUNT @ 0 > if
      0 STATUS-TS !
      ROW-COUNT @ 0 ?do i ROW-LAST @ STATUS-TS @ max STATUS-TS ! loop
      STATUS-TS @ TIMEZONE-MIN @ 60 * + FORMAT-SOURCE-DATE FIND-ROW STATUS-INDEX !
   then
   JSON-FLAG @ 0= if REPORT-STATUS-TEXT exit then
   s" {" RAW s" kind" KEY s" statusline" STR s" ," RAW
   s" last_date" KEY
   ROW-COUNT @ 0= if
      s" null" RAW
      s" ," RAW s" totals" KEY s" {}" RAW
   else
      STATUS-INDEX @ {: idx:n :}
      idx ROW-KEY$ STR s" ," RAW
      s" totals" KEY idx STATUS-TOTALS
   then
   s" }" RAW LF-BYTE 1 RAW ;


public
: MAIN ( -- )
   PARSE-ARGS
   \ A closed stdout is still ignored by help and reported by other commands.
   [: 1 >FD FD-NOSIGPIPE! ;] catch 0<> if
      MODE @ HELP-MODE = if exit then WRITE-FAIL
   then
   MODE @ HELP-MODE = if HELP exit then
   INSTALL-WALK
   COLLECT
   MODE @ STATUSLINE = if REPORT-STATUS else REPORT-PERIOD then OUT-FLUSH ;
;package

: MAIN ( -- ) ZU:MAIN ;
