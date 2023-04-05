# F3DEX2
Matching and mostly documented disassemblies of the F3DEX2/F3DZEX2 N64 RSP microcode family.

#### Terminology:
* **NoN** - No Nearclipping
* **fifo** - RDP Commands are written to a buffer in RDRAM.
* **xbus** - RDP Commands are written to a buffer in RSP memory.

#### Currently matches the following F3DEX2 microcodes:
* **2.04**
  * **fifo** (Goemon's Great Adventure)
  * **NoN fifo** (California Speed)
* **2.04H**
  * **fifo** (Kirby 64, Smash 64)
* **2.05**
  * **fifo** (Snowboard Kids 2)
  * **NoN fifo** (The New Tetris)
* **2.06**
  * **fifo** (Pokemon Stadium)
  * **NoN fifo** (Mario Party)
  * **NoN xbus** (Command & Conquer)
* **2.07**
  * **fifo** (Rocket: Robot on Wheels)
  * **NoN fifo** (Tom Clancy's Rainbox Six)
  * **xbus** (Lode Runner 3-D)
* **2.08**
  * **fifo** (Banjo-Tooie)
  * **NoN fifo** (Mario Party 2 and 3)
  * **xbus** (Power Rangers)
  * **NoN xbus** (Excitebike 64)
* **2.08 with point lighting**
  * **fifo** (Paper Mario, Pokemon Stadium 2)
* **2.08H**
  * **NoN fifo** (Pokemon Snap)

#### Also matches the following F3DZEX2 microcodes:
* **2.06H**
    * **NoN fifo** (Ocarina of Time)
* **2.08I**
    * **NoN fifo** (Majora's Mask, Gamecube Ocarina of Time)
* **2.08J**
    * **NoN fifo** (Animal Forest)

The games listed are just examples; most microcodes are used in more than one game. Some games also have more than one microcode and switch between them during gameplay, so they may have multiple of the ones in this list.

Other combinations of supported versions and flags should also match after being added to `ucodes_database.mk`.
