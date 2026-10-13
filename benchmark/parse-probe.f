\ Standalone conversion probe for pinned Habu c53b4d2c.
\ Each pass parses both decimal spellings and consumes their IEEE bits.
require lib/f64-text.f
require lib/time.f
require lib/ieee754.f

package F64-REPRO
using F64-TEXT
using IEEE754

241400 constant PAIRS
variable CHECKSUM

: PARSE-ONE ( ptr u8 n -- )
   PARSE MATCH result
      ok OF F64>BITS CHECKSUM +! ENDOF
      err OF drop -1 throw ENDOF
   ;MATCH ;

public
: RUN ( -- )
   TIME:MONO-NS {: began:n :}
   PAIRS 0 do
      s" 0" PARSE-ONE
      s" 1.25" PARSE-ONE
   loop
   TIME:MONO-NS began - .
   CHECKSUM @ . cr ;
;package

: MAIN ( -- ) F64-REPRO:RUN ;
