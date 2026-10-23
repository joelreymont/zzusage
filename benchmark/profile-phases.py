"""Generate a diagnostic copy of main.f with inclusive phase timers.

Usage: python3 benchmark/profile-phases.py main.f .build/profile/phase.f
Compile the generated source with the Habu builder build.sh uses. Run that executable
only with synthetic HOME and explicit fixture roots. Timers add overhead and
nest: use them for attribution, not controlled performance comparisons. Metrics
are written to stderr; compare stdout with an uninstrumented reference.
"""
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
items=[('PARSE-JSON','ptr u8 n --'),('EVENT-TIME','-- n'),('FIND-ROW','ptr u8 n -- n'),('SET-ADD','n n ptr u8 n --'),('EVENT-COST','-- r'),('RESERVE-ROWS','n --'),('POOL-ADD','ptr u8 n -- n'),('PARSE-FILE-CONTENT','n --'),('COLLECT','--'),('SORT-ROWS','--'),('MONEY','r --'),('REPORT-PERIOD','--'),('REPORT-STATUS','--')]
source=source.replace('require src/lib/string.f','require src/lib/time.f\nrequire src/lib/string.f',1)
decls='\n'.join(f'variable P-{name}-NS\nvariable P-{name}-N' for name,_ in items)
source=source.replace('package ZU','package ZU\n'+decls+'''\nvariable P-WRITE-NS
variable P-WRITE-N
variable P-WRITE-BYTES
variable P-READ-NS
variable P-READ-N
: P-WRITE ( n ptr u8 n -- n )
   dup P-WRITE-BYTES +! 1 P-WRITE-N +!
   TIME:MONO-NS {: began:n :} write TIME:MONO-NS began - P-WRITE-NS +! ;
: P-READ ( n ptr u8 n -- n )
   1 P-READ-N +!
   TIME:MONO-NS {: began:n :} read TIME:MONO-NS began - P-READ-NS +! ;
''',1)
source=source.replace('1 -rot write','1 -rot P-WRITE').replace('FILE-PROBE 1 read','FILE-PROBE 1 P-READ').replace('FILE-ALLOC @ FILE-U @ - read','FILE-ALLOC @ FILE-U @ - P-READ')
for name,sig in items:
 old=f': {name} (';start=source.index(old);end=source.index('\n:',start+len(old))
 source=source[:end]+f'\n: {name} ( {sig} )\n   1 P-{name}-N +! TIME:MONO-NS {{: began:n :}} P-BASE-{name}\n   TIME:MONO-NS began - P-{name}-NS +! ;\n'+source[end:]
 source=source[:start]+source[start:].replace(old,f': P-BASE-{name} (',1)
report='''\n: P-METRIC ( ptr u8 n n -- ) {: a:ptr u:n value:n :}
   2 a u write drop 2 s" " write drop
   value U$ {: digits:ptr length:n :} 2 digits length write drop
   2 LF-BYTE 1 write drop ;
: P-REPORT ( -- )
'''
for name,_ in items:report+=f'   s" {name}-ns=" P-{name}-NS @ P-METRIC\n   s" {name}-calls=" P-{name}-N @ P-METRIC\n'
for name in ['WRITE-NS','WRITE-N','WRITE-BYTES','READ-NS','READ-N']:report+=f'   s" {name}=" P-{name} @ P-METRIC\n'
report+=';\n'
source=source.replace('\n: MAIN ( -- )','\n'+report+'\n: MAIN ( -- )',1)
source=source.replace('if REPORT-STATUS else REPORT-PERIOD then ;','if REPORT-STATUS else REPORT-PERIOD then P-REPORT ;',1)
source=source.replace('if REPORT-STATUS else REPORT-PERIOD then OUT-FLUSH ;','if REPORT-STATUS else REPORT-PERIOD then OUT-FLUSH P-REPORT ;',1)
Path(sys.argv[2]).write_text(source)
