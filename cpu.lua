local NES =
    Nes or
    {-- DUMMY NES
        RP2A03_CC = 12,
        FOREVER_CLOCK = 0xffffffff
    }
CPU = {}
local CPU = CPU
CPU._mt = {__index = CPU}

do
    CPU.CLK = {}
    local clocks = {1, 2, 3, 4, 5, 6, 7, 8}
    for i = 1, #clocks do
        CPU.CLK[i] = clocks[i] * NES.RP2A03_CC
    end
end
CPU.UNDEFINED = {}
CPU.RAM_SIZE = 0x0800
CPU.MAINMEM_SIZE = 0x10000
CPU.NMI_VECTOR   = 0xfffa
CPU.RESET_VECTOR = 0xfffc
CPU.IRQ_VECTOR   = 0xfffe

CPU.IRQ_EXT   = 0x01
CPU.IRQ_FRAME = 0x40
CPU.IRQ_DMC = 0x80

local UNDEFINED = CPU.UNDEFINED
local CLK = CPU.CLK

local nthBitIsSet = UTILS.nthBitIsSet
local isDefined = UTILS.isDefined
local bind = UTILS.bind
local tSetter = UTILS.tSetter
local tGetter = UTILS.tGetter
local fill = UTILS.fill
local range = UTILS.range
local map = UTILS.map
local flat_map = UTILS.flat_map
local uniq = UTILS.uniq
local clear = UTILS.clear
local all = UTILS.all
local copy = UTILS.copy
local nthBitIsSetInt = UTILS.nthBitIsSetInt
local transpose = UTILS.transpose

CPU.PokeNop = function()
end

function CPU:steal_clocks(clk)
    self.clk = self.clk + clk
end

function CPU:odd_clock()
    return ((self.clk_total + self.clk) % CLK[2]) ~= 0
end

function CPU:update()
    self.apu.clock_dma(self.clk)
    return self.clk
end

function CPU:dmc_dma(addr)
    -- This is inaccurate; it must steal *up to* 4 clocks depending upon
    -- whether CPU writes in this clock, but this always steals 4 clocks.
    self.clk = self.clk + CLK[3]
    local dma_buffer = self:fetch(addr)
    self.clk = self.clk + CLK[1]
    return dma_buffer
end

function CPU:next_frame_clock()
    return self.clk_next_frame
end

function CPU:next_frame_clock(x)
    if x then
        self.clk_next_frame = x
        self.clk_target = x < self.clk_target and x or self.clk_target
    end
    return self.clk_next_frame
end
function CPU:current_clock()
    return self.clk
end

function CPU:peek_nop(addr)
    return bit.rshift(addr, 8)
end

function CPU:peek_jam_1(addr)
    self._pc = bit.band(self._pc - 1, 0xffff)
    return 0xfc
end
function CPU:peek_jam_2(_addr)
    return 0xff
end

function CPU:peek_ram(addr)
    return self.ram[addr % CPU.RAM_SIZE+1]
end
function CPU:poke_ram(addr, data)
    self.ram[addr % CPU.RAM_SIZE+1] = data
end

function CPU:fetch(addr)
    local v =  self._fetch[addr]
    --[[
    print("FETCH")
    print(addr)
    print(v)
    print(v(addr))
    print("FETCHE")
    --]]
    v = (type(v) ~= "table" or v ~= UNDEFINED) and v or nil
    return v and v(addr) or nil
end
function CPU:store(addr, value)
    return self._store[addr](addr, value)
end

function CPU:peek16(addr)
  local a = self:fetch(addr)
  local b = bit.lshift(self:fetch(addr + 1), 8)
  local x = a + b
  --[[
    print "peek16"
    UTILS.print(a)
    UTILS.print(b)
    UTILS.print(addr)
    UTILS.print(x)
    --]]
    return x
end

function CPU:add_mappings(addr, peek, poke)
    self.peeks[peek] = isDefined(self.peeks[peek]) or peek
    peek = self.peeks[peek]
    self.pokes[poke] = isDefined(self.pokes[poke]) or poke
    poke = self.pokes[poke]
    if type(addr) == "number" then
        addr = {addr}
    end
    for i = 1, #addr do
        local x = addr[i]
        self._fetch[x] = peek
        self._store[x] = (poke and type(poke)=="table" and poke ~= UNDEFINED) and poke or CPU.PokeNop
    end
end

function CPU:reset()
    self._a = 0
    self._x = 0
    self._y = 0
    self._sp = 0xfd
    self._pc = 0xfffc
    self._p_nz = 1
    self._p_c = 0
    self._p_v = 0
    self._p_i = 0x04
    self._p_d = 0
    fill(self.ram, 0xff)
    self.clk = 0
    self.clk_total = 0
    self:add_mappings(range(0x0000, 0x07ff), tGetter(self.ram), tSetter(self.ram))
    self:add_mappings(range(0x0800, 0x1fff), bind(self.peek_ram, self), bind(self.poke_ram, self))
    self:add_mappings(range(0x2000, 0xffff), bind(self.peek_nop, self), UNDEFINED)
    self:add_mappings(0xfffc, bind(self.peek_jam_1, self), UNDEFINED)
    self:add_mappings(0xfffd, bind(self.peek_jam_2, self), UNDEFINED)
end

function CPU:new(conf)
    local cpu = {}
    setmetatable(cpu, CPU._mt)
    cpu.conf = conf or {loglevel=-1}
    cpu.ram = fill({}, CPU.UNDEFINED, CPU.RAM_SIZE)
    cpu._store = fill({}, CPU.UNDEFINED, CPU.MAINMEM_SIZE)
    cpu._fetch = fill({}, CPU.UNDEFINED, CPU.MAINMEM_SIZE)
    cpu.peeks = {}
    cpu.pokes = {}
    cpu.clk = 0 -- the current clock
    cpu.clk_frame = 0
    cpu.clk_next_frame = 0 -- the next frame clock
    cpu.clk_target = 0 -- the goal clock for the current CPU#run
    cpu.clk_total = 0 -- the total elapsed clocks
    cpu.clk_nmi = NES.FOREVER_CLOCK -- the next NMI clock (NES.FOREVER_CLOCK means "not scheduled")
    cpu.clk_irq = NES.FOREVER_CLOCK -- the next IRQ clock
    cpu.irq_flags = 0
    cpu.jammed = false
    cpu:reset()
    cpu.data = 0
    cpu.addr = 0
    cpu.opcode = nil
    cpu.ppu_sync = nil
    -- DUMMY APU
    cpu.apu = {
        clock_dma = function(clk) end,
        do_clock = function() return CLK[1] end,
    }
    return cpu
end

function CPU:dmc_dma(addr)
    -- This is inaccurate; it must steal *up to* 4 clocks depending upon
    -- whether CPU writes in this clock, but this always steals 4 clocks.
    self.clk = CLK[3] + self.clk
    local dma_buffer = self:fetch(addr)
    self.clk = CLK[1] + self.clk
    return dma_buffer
end

function CPU:sprite_dma(addr, sp_ram)
    for i = 0, 255 do
        sp_ram[i] = self.ram[addr + i+1]
    end
    for i = 0, 63 do
        sp_ram[i * 4 + 2] = bit.band(sp_ram[i * 4 + 2], 0xe3)
    end
end

function CPU:boot()
    self.clk = CLK[7]
    self._pc = self:peek16(CPU.RESET_VECTOR)
end

function CPU:vsync()
    if self.ppu_sync then
        self.ppu.sync(self.clk)
    end

    self.clk = self.clk - self.clk_frame
    self.clk_total = self.clk_target + self.clk_frame

    if self.clk_nmi ~= NES.FOREVER_CLOCK then
        self.clk_nmi = self.clk_nmi - self.clk_frame
    end
    if self.clk_irq ~= NES.FOREVER_CLOCK then
        self.clk_irq = self.clk_irq - self.clk_frame
    end
    if self.clk_irq < 0 then
        self.clk_irq = 0
    end
end

-------------------------------------------------------------------------------------------------------------------
-- interrupts

function CPU:clear_irq(line)
    local old_irq_flags = bit.band(self.irq_flags, bit.bor(CPU.IRQ_FRAME, CPU.IRQ_DMC))
    self.irq_flags = bit.band(self.irq_flags, line ^ bit.bor(bit.bor(CPU.IRQ_EXT, CPU.IRQ_FRAME), CPU.IRQ_DMC))
    if self.irq_flags == 0 then
        self.clk_irq = NES.FOREVER_CLOCK
    end
    return old_irq_flags
end

function CPU:next_interrupt_clock(clk)
    clk = clk + CLK[1] + CLK[1] / 2 -- interrupt edge
    if self.clk_target > clk then
        self.clk_target = clk
    end
    return clk
end

function CPU:do_irq(line, clk)
    self.irq_flags = bit.bor(self.irq_flags, line)
    if self.clk_irq == NES.FOREVER_CLOCK and self._p_i == 0 then
        self.clk_irq = self:next_interrupt_clock(clk)
    end
end

function CPU:do_nmi(clk)
    if self.clk_nmi == NES.FOREVER_CLOCK then
        self.clk_nmi = self:next_interrupt_clock(clk)
    end
end

function CPU:do_isr(vector)
    if self.jammed then
        return
    end
    self:push16(self._pc)
    self:push8(self:flags_pack())
    self._p_i = 0x04
    self.clk = self.clk + CLK[7]
    local addr = vector == CPU.NMI_VECTOR and CPU.NMI_VECTOR or self:fetch_irq_isr_vector()
    self._pc = self:peek16(addr)
end

function CPU:fetch_irq_isr_vector()
    if self.clk >= self.clk_frame then
        self:fetch(0x3000)
    end
    if self.clk_nmi ~= NES.FOREVER_CLOCK then
        if self.clk_nmi + CLK[2] <= self.clk then
            self.clk_nmi = NES.FOREVER_CLOCK
            return CPU.NMI_VECTOR
        end
        self.clk_nmi = self.clk + 1
    end
    return CPU.IRQ_VECTOR
end

------------------------------------------------------------------------------------------------------------------------
-- instruction helpers

------ P regeister ------

function CPU:flags_pack()
    return bit.bor(
        bit.bor(
            bit.bor(
                bit.bor(
                    bit.bor(
                        bit.bor(
                            bit.band(bit.rshift(bit.bor(self._p_nz, self._p_nz), 1), 0x80),
                            (bit.band(self._p_nz, 0xff) ~= 0 and 0 or 2)
                        ),
                        self._p_c
                    ),
                    self._p_v ~= 0 and 0x40 or 0
                ),
                self._p_i
            ),
            self._p_d
        ),
        0x20
    )
    --[[
        -- NVssDIZC
      ((self._p_nz | self._p_nz >> 1) & 0x80) | -- N: Negative
        (self._p_nz & 0xff ~= 0 ? 0 : 2) |  -- Z: Zero
        self._p_c |                         -- C: Carry
        (self._p_v ~= 0 ? 0x40 : 0) |       -- V: Overflow
        self._p_i |                         -- I: Inerrupt
        self._p_d |                         -- D: Decimal
        0x20
        --]]
end

function CPU:flags_unpack(f)
    self._p_nz = bit.bor(bit.band(bit.bnot(f), 2), bit.lshift(bit.band(f, 0x80), 1))
    self._p_c = bit.band(f, 0x01)
    self._p_v = bit.band(f, 0x40)
    self._p_i = bit.band(f, 0x04)
    self._p_d = bit.band(f, 0x08)
end

------ branch helper ------
function CPU:branch(cond)
    if cond then
        local tmp = self._pc + 1
        local rel = self:fetch(self._pc)
        self._pc = bit.band(tmp + (rel < 128 and rel or bit.bor(rel, 0xff00)), 0xffff)
        self.clk = self.clk + (nthBitIsSetInt(tmp,8) == nthBitIsSetInt(self._pc,8) and CLK[3] or CLK[4])
    else
        self._pc = self._pc + 1
        self.clk = self.clk + CLK[2]
    end
end

------ storers ------
function CPU:store_mem()
    self:store(self.addr, self.data)
    self.clk = self.clk + CLK[1]
end

function CPU:store_zpg()
    self.ram[self.addr+1] = self.data
end

------ stack management ------
function CPU:push8(data)
    self.ram[0x0100 + self._sp+1] = data
    self._sp = bit.band((self._sp - 1), 0xff)
end

function CPU:push16(data)
    self:push8(bit.rshift(data, 8))
    self:push8(bit.band(data, 0xff))
end

function CPU:pull8()
    self._sp = bit.band(self._sp + 1, 0xff)
    return self.ram[0x0100 + self._sp+1]
end

function CPU:pull16()
    local x = self:pull8()
    return x + 256 * x
end

------------------------------------------------------------------------------------------------------------------------
-- addressing modes

-- immediate addressing (read only)
function CPU:imm(_read, _write)
    self.data = self:fetch(self._pc)
    self._pc = self._pc + 1
    self.clk = self.clk + CLK[2]
end

-- zero-page addressing
function CPU:zpg(read, write)
    self.addr = self:fetch(self._pc)
    self._pc = self._pc + 1
    self.clk = self.clk + CLK[3]
    if read then
        self.data = self.ram[self.addr+1]
        if write then
            self.clk = self.clk + CLK[2]
        end
    end
end

-- zero-page indexed addressing
function CPU:zpg_reg(indexed, read, write)
    self.addr = bit.band(indexed + self:fetch(self._pc), 0xff)
    self._pc = self._pc + 1
    self.clk = self.clk + CLK[4]
    if read then
        self.data = self.ram[self.addr+1]
        if write then
            self.clk = self.clk + CLK[2]
        end
    end
end

function CPU:zpg_x(read, write)
    return self:zpg_reg(self._x, read, write)
end

function CPU:zpg_y(read, write)
    return self:zpg_reg(self._y, read, write)
end

-- absolute addressing
function CPU:abs(read, write)
    self.addr = self:peek16(self._pc)
    self._pc = self._pc + 2
    self.clk = self.clk + CLK[3]
    return self:read_write(read, write)
end

-- absolute indexed addressing
function CPU:abs_reg(indexed, read, write)
    local addr = self._pc + 1
    local i = indexed + self:fetch(self._pc)
    self.addr = bit.band(bit.lshift(self:fetch(addr), 8) + i, 0xffff)
    if write then
        addr = bit.band(self.addr - bit.band(i, 0x100), 0xffff)
        self:fetch(addr)
        self.clk = self.clk + CLK[4]
    else
        self.clk = self.clk + CLK[3]
        if bit.band(i, 0x100) ~= 0 then
            addr = bit.band(self.addr - 0x100, 0xffff) -- for inlining fetch
            self:fetch(addr)
            self.clk = self.clk + CLK[1]
        end
    end
    self:read_write(read, write)
    self._pc = self._pc + 2
end

function CPU:abs_x(read, write)
    return self:abs_reg(self._x, read, write)
end

function CPU:abs_y(read, write)
    return self:abs_reg(self._y, read, write)
end
-- indexed indirect addressing
function CPU:ind_x(read, write)
    local addr = self:fetch(self._pc) + self._x
    self._pc = self._pc + 1
    self.clk = self.clk + CLK[5]
    self.addr = bit.bor(self.ram[bit.band(addr, 0xff)+1], bit.lshift(self.ram[1+bit.band(addr + 1, 0xff)], 8))
    return self:read_write(read, write)
end

-- indirect indexed addressing
function CPU:ind_y(read, write)
    local addr = self:fetch(self._pc)
    self._pc = self._pc + 1
    local indexed = self.ram[addr+1] + self._y
    self.clk = self.clk + CLK[4]
    if write then
        self.clk = self.clk + CLK[1]
        self.addr = bit.lshift(self.ram[bit.band(addr + 1, 0xff)+1], 8) + indexed
        addr = self.addr - bit.band(indexed, 0x100) -- for inlining fetch
        self:fetch(addr)
    else
        self.addr = bit.band(bit.lshift(self.ram[bit.band(addr + 1, 0xff)+1], 8) + indexed, 0xffff)
        if bit.band(indexed, 0x100) ~= 0 then
            addr = bit.band(self.addr - 0x100, 0xffff) -- for inlining fetch
            self:fetch(addr)
            self.clk = self.clk + CLK[1]
        end
    end
    return self:read_write(read, write)
end


    function CPU:read_write(read, write)
      if read then
        self.data = self:fetch(self.addr)
        self.clk =self.clk + CLK[1]
        if write then
          self:store(self.addr, self.data)
          self.clk =self.clk + CLK[1]
        end
      end
    end

    --------------------------------------------------------------------------------------------------------------------
    -- instructions

    -- load instructions
    function CPU:_lda()
      self._p_nz = self.data
      self._a = self.data
    end

    function CPU:_ldx()
      self._p_nz = self.data
      self._x = self.data
    end

    function CPU:_ldy()
      self._y = self.data
      self._p_nz = self.data
    end

    -- store instructions
    function CPU:_sta()
      self.data = self._a
    end

    function CPU:_stx()
      self.data = self._x
    end

    function CPU:_sty()
      self.data = self._y
    end

    -- transfer instructions
    function CPU:_tax()
      self.clk =self.clk + CLK[2]
      self._x = self._a
      self._p_nz = self._a
    end

    function CPU:_tay()
      self.clk =self.clk + CLK[2]
      self._y = self._a
      self._p_nz = self._a
    end

    function CPU:_txa()
      self.clk =self.clk + CLK[2]
      self._a = self._x
      self._p_nz = self._x
    end

    function CPU:_tya()
      self.clk =self.clk + CLK[2]
      self._a = self._y
      self._p_nz = self._y
    end

    -- flow control instructions
    function CPU:_jmp_a()
      self._pc = self:peek16(self._pc)
      self.clk =self.clk + CLK[3]
    end

    function CPU:_jmp_i()
      local pos = self:peek16(self._pc)
      local low = self:fetch(pos)
      pos = bit.bor(bit.band(pos, 0xff00), bit.band(pos + 1, 0x00ff))
      local high = self:fetch(pos)
      self._pc = high * 256 + low
      self.clk =self.clk + CLK[5]
    end

    function CPU:_jsr()
      local data = self._pc + 1
      self:push16(data)
      self._pc = self:peek16(self._pc)
      self.clk =self.clk + CLK[6]
    end

    function CPU:_rts()
      self._pc = bit.band(self:pull16() + 1, 0xffff)
      self.clk =self.clk + CLK[6]
    end

    function CPU:_rti()
      self.clk =self.clk + CLK[6]
      local packed = self:pull8()
      self._pc = self:pull16()
      self:flags_unpack(packed)
      if self.irq_flags == 0 or self._p_i ~= 0 then
        self.clk_irq =NES.FOREVER_CLOCK
      else
        self.clk_target = 0
        self.clk_irq = 0
      end
    end

    function CPU:_bne()
      return self:branch(bit.band(self._p_nz , 0xff) ~= 0)
    end

    function CPU:_beq()
      return self:branch(bit.band(self._p_nz , 0xff) == 0)
    end

    function CPU:_bmi()
      return self:branch(bit.band(self._p_nz , 0x180) ~= 0)
    end

    function CPU:_bpl()
      return self:branch(bit.band(self._p_nz , 0x180) == 0)
    end

    function CPU:_bcs()
      return self:branch(self._p_c ~= 0)
    end

    function CPU:_bcc()
      return self:branch(self._p_c == 0)
    end

    function CPU:_bvs()
      return self:branch(self._p_v ~= 0)
    end

    function CPU:_bvc()
      return self:branch(self._p_v == 0)
    end

    -- math operations
    function CPU:_adc()
      local tmp = self._a + self.data + self._p_c
      self._p_v = bit.band(bit.bnot(self._a ^ self.data), bit.band((self._a ^ tmp), 0x80))
       self._a = bit.band(tmp, 0xff)
      self._p_nz =self._a
      self._p_c = tmp[8]
    end

    function CPU:_sbc()
      local data = self.data ^ 0xff
      local tmp = self._a + data + self._p_c
      self._p_v = bit.band(bit.bnot(self._a ^ data), bit.band((self._a ^ tmp) , 0x80))
       self._a = bit.band(tmp , 0xff)
      self._p_nz =self._a
      self._p_c = tmp[8]
    end

    -- logical operations
    function CPU:_and()
         self._a = bit.band(self._a,self.data)
      self._p_nz =self._a
    end

    function CPU:_ora()
        self._a =bit.bor(self._a, self.data)
      self._p_nz = self._a
    end

    function CPU:_eor()
        self._a = ( self._a ^self.data)
      self._p_nz = self._a
    end

    function CPU:_bit()
      self._p_nz = bit.bor((bit.band(self.data , self._a) ~= 0 and 1 or 0) ,bit.lshift(bit.band(self.data, 0x80), 1))
      self._p_v = bit.band(self.data , 0x40)
    end

    function CPU:_cmp()
      local data = self._a - self.data
      self._p_nz = bit.band(data , 0xff)
      self._p_c = 1 - data[8]
    end

    function CPU:_cpx()
      local data = self._x - self.data
      self._p_nz = bit.band(data , 0xff)
      self._p_c = 1 - data[8]
    end

    function CPU:_cpy()
      local data = self._y - self.data
      self._p_nz = bit.band(data, 0xff)
      self._p_c = 1 - data[8]
    end

    -- shift operations
    function CPU:_asl()
      self._p_c = bit.rshift(self.data, 7)
      self._p_nz = bit.band(bit.lshift(self.data, 1), 0xff)
      self.data = self._p_nz
    end

    function CPU:_lsr()
      self._p_c = bit.band(self.data, 1)
       self._p_nz = bit.rshift(self.data ,1)
      self.data =self._p_nz
    end

    function CPU:_rol()
      self._p_nz = bit.bor(bit.band(bit.lshift(self.data, 1), 0xff), self._p_c)
      self._p_c = bit.rshift(self.data, 7)
      self.data = self._p_nz
    end

    function CPU:_ror()
      self._p_nz = bit.bor(bit.rshift(self.data, 1), bit.lshift(self._p_c, 7))
      self._p_c = bit.band(self.data, 1)
      self.data = self._p_nz
    end

    -- increment and decrement operations
    function CPU:_dec()
        self._p_nz = bit.band(self.data - 1, 0xff)
      self.data = self._p_nz
    end

    function CPU:_inc()
        self._p_nz = bit.band(self.data + 1,0xff)
      self.data = self._p_nz
    end

    function CPU:_dex()
      self.clk =self.clk + CLK[2]
      local x = bit.band(self._x - 1, 0xff)
      self.data = x
      self._p_nz = x
      self._x = x
    end

    function CPU:_dey()
      self.clk =self.clk + CLK[2]
      self._y = bit.band(self._y - 1, 0xff)
      self.data = self._y
      self._p_nz = self._y
    end

    function CPU:_inx()
      self.clk =self.clk + CLK[2]
      self._x = bit.band(self._x + 1, 0xff)
      self.data = self._x
      self._p_nz = self._x
    end

    function CPU:_iny()
      self.clk =self.clk + CLK[2]
      self._y = bit.band(self._y + 1, 0xff)
      self.data = self._y
      self._p_nz = self._y
    end

    -- flags instructions
    function CPU:_clc()
      self.clk =self.clk + CLK[2]
      self._p_c = 0
    end

    function CPU:_sec()
      self.clk =self.clk + CLK[2]
      self._p_c = 1
    end

    function CPU:_cld()
      self.clk = CLK[2]+self.clk
      self._p_d = 0
    end

    function CPU:_sed()
      self.clk =self.clk + CLK[2]
      self._p_d = 8
    end

    function CPU:_clv()
      self.clk =self.clk + CLK[2]
      self._p_v = 0
    end

    function CPU:_sei()
      self.clk =self.clk + CLK[2]
      if self._p_i == 0 then
        self._p_i = 0x04
        self.clk_irq = NES.FOREVER_CLOCK
        if self.irq_flags ~= 0 then self:do_isr(CPU.IRQ_VECTOR) end
      end
    end

    function CPU:_cli()
      self.clk =self.clk + CLK[2]
      if self._p_i ~= 0 then
        self._p_i = 0
        if self.irq_flags ~= 0 then
          local clk = self.clk + 1
            self.clk_irq = clk
          if self.clk_target > clk then self.clk_target = clk end
        end
      end
    end

    -- stack operations
    function CPU:_pha()
      self.clk =self.clk + CLK[3]
      return self:push8(self._a)
    end

    function CPU:_php()
      self.clk =self.clk + CLK[3]
      local data = bit.bor(self:flags_pack(),0x10)
      return self:push8(data)
    end

    function CPU:_pla()
      self.clk =self.clk + CLK[4]
      self._a = self:pull8()
      self._p_nz = self._a
    end

    function CPU:_plp()
      self.clk =self.clk + CLK[4]
      local i = self._p_i
      self:flags_unpack(self:pull8())
      if self.irq_flags ~= 0 then
        if i > self._p_i then
          local clk =  self.clk + 1
          self.clk_irq =clk
          if self.clk_target > clk then self.clk_target = clk end
        elseif i < self._p_i then
          self.clk_irq = NES.FOREVER_CLOCK
          self:do_isr(CPU.IRQ_VECTOR)
        end
      end
    end

    function CPU:_tsx()
      self.clk =self.clk + CLK[2]
      self._p_nz = self._sp
      self._x = self._sp
    end

    function CPU:_txs()
      self.clk =self.clk + CLK[2]
      self._sp = self._x
    end

    -- undocumented instructions, rarely used
    function CPU:_anc()
        self._a = bit.band(self._a,self.data)
      self._p_nz = self._a
      self._p_c = bit.rshift(self._p_nz, 7)
    end

    function CPU:_ane()
      self._a = bit.band(bit.band(bit.bor(self._a, 0xee), self._x), self.data)
      self._p_nz = self._a
    end

    function CPU:_arr()
      self._a = bit.bor(bit.rshift(bit.band(self.data, self._a), 1), bit.lshift(self._p_c, 7))
      self._p_nz = self._a
      self._p_c = self._a[6]
      self._p_v = self._a[6] ^ self._a[5]
    end

    function CPU:_asr()
      self._p_c = bit.band(bit.band(self.data, self._a), 0x1)
      self._a = bit.rshift(bit.band(self.data,self._a), 1)
      self._p_nz = self._a
    end

    function CPU:_dcp()
      self.data = bit.band(self.data - 1,0xff)
      return self:_cmp()
    end

    function CPU:_isb()
      self.data = bit.band(self.data + 1, 0xff)
      return self:_sbc()
    end

    function CPU:_las()
      self._sp =bit.band(self._sp, self.data)
       self._x = self._sp
      self._p_nz = self._x
      self._a =self._x
    end

    function CPU:_lax()
         self._x = self.data
      self._p_nz =self._x
       self._a =self._x
    end

    function CPU:_lxa()
        self._x = self.data
      self._p_nz =self._x
       self._a = self._x
    end

    function CPU:_rla()
      local c = self._p_c
      self._p_c = bit.rshift(self.data, 7)
      self.data = bit.bor(bit.band(bit.lshift(self.data, 1), 0xff), c)
      self._a =bit.band( self._a,self.data)
      self._p_nz = self._a
    end

    function CPU:_rra()
      local c = bit.lshift(self._p_c ,7)
      self._p_c = bit.band(self.data , 1)
      self.data = bit.bor(bit.rshift(self.data ,1), c)
      return self:_adc()
    end

    function CPU:_sax()
      self.data = bit.band(self._a, self._x)
    end

    function CPU:_sbx()
      self.data = bit.band(self._a, self._x) - self.data
      self._p_c = bit.band(self.data, 0xffff) <= 0xff and 1 or 0
       self._x = bit.band(self.data , 0xff)
      self._p_nz =self._x
    end

    function CPU:_sha()
      self.data = bit.band(self._a ,bit.band(self._x, (bit.rshift(self.addr, 8) + 1)))
    end

    function CPU:_shs()
      self._sp = bit.band(self._a, self._x)
      self.data = bit.band(self._sp, (bit.rshift(self.addr, 8) + 1))
    end

    function CPU:_shx()
      self.data = bit.band(self._x, (bit.rshift(self.addr, 8) + 1))
      self.addr = bit.bor(bit.lshift(self.data, 8),bit.band(self.addr, 0xff))
    end

    function CPU:_shy()
      self.data = bit.band(self._y, (bit.rshift(self.addr, 8) + 1))
      self.addr = bit.bor(bit.lshift(self.data, 8), bit.band(self.addr, 0xff))
    end

    function CPU:_slo()
      self._p_c = bit.rshift(self.data, 7)
      self.data = bit.band(bit.lshift(self.data, 1), 0xff)
      self._a =bit.bor( self.data, self._a)
      self._p_nz = self._a
    end

    function CPU:_sre()
      self._p_c = bit.band(self.data,1)
      self.data =bit.rshift(self.data, 1)
      self._a = bit.bxor(self._a, self.data)
      self._p_nz = self._a
    end

    -- nops
    function CPU:_nop()
    end

    -- interrupts
    function CPU:_brk()
      local data = self._pc + 1
      self:push16(data)
      data = bit.bor(self:flags_pack(), 0x10)
      self:push8(data)
      self._p_i = 0x04
      self.clk_irq = NES.FOREVER_CLOCK
      self.clk =self.clk + CLK[7]
      local addr = self:fetch_irq_isr_vector() -- for inlining peek16
      self._pc = self:peek16(addr)
    end

    function CPU:_jam()
      self._pc = bit.band((self._pc - 1) ,0xffff)
      self.clk =      self.clk + CLK[2]
      if not self.jammed then
        self.jammed = true
        -- interrupt reset
        self.clk_nmi = NES.FOREVER_CLOCK
        self.clk_irq = NES.FOREVER_CLOCK
        self.irq_flags = 0
      end
    end

    --------------------------------------------------------------------------------------------------------------------
    -- default core

    function CPU:r_op(instr, mode)
      self[mode](self, true, false)
      self[instr](self)
    end

    function CPU:w_op(instr, mode, store)
      self[mode](self, false, true)
      self[instr](self)
      self[store](self)
    end

    function CPU:rw_op(instr, mode, store)
      self[mode](self, true, true)
      self[instr](self)
      self[store](self)
    end

    function CPU:a_op(instr)
      self.clk =self.clk + CLK[2]
      self.data = self._a
      self[instr](self)
      self._a = self.data
    end

    function CPU:no_op(_instr, ops, ticks)
      self._pc =self._pc  + ops
      self.clk =self.clk + ticks * NES.RP2A03_CC
    end

    function CPU:do_clock()
      local clock = self.apu.do_clock()

       if clock > self.clk_frame then clock = self.clk_frame end

      if self.clk < self.clk_nmi then
        if clock > self.clk_nmi then clock = self.clk_nmi end
        if self.clk < self.clk_irq then
          if clock > self.clk_irq then clock = self.clk_irq end
        else
          self.clk_irq = NES.FOREVER_CLOCK
            self:do_isr(CPU.IRQ_VECTOR)
        end
      else
        self.clk_nmi = NES.FOREVER_CLOCK
        self.clk_irq = NES.FOREVER_CLOCK
        self:do_isr(CPU.NMI_VECTOR)
      end
      self.clk_target = clock
    end
    local asd = 0
    function CPU:run()
      self:do_clock()
      repeat
        repeat
          self.opcode = self:fetch(self._pc)
          print(string.format("%u %u %s \t %u %u %u %u %d %u", self.addr, self.data, table.concat(CPU.DISPATCH[self.opcode], " "),self._a, self._x, self._y, self._p_c, self._pc, self.clk))
          if self.conf.loglevel >= 3 then
            self.conf.debug(string.format("PC:%04X A:%02X X:%02X Y:%02X P:%02X SP:%02X CYC:%3d : OPCODE:%02X (%d, %d)" ,
              self._pc, self._a, self._x, self._y, self:flags_pack(), self._sp, self.clk / 4 % 341, self.opcode, self.cl
            ))
          end

          self._pc =self._pc + 1

          local operationData = CPU.DISPATCH[self.opcode]
          if not operationData then
          end
            local f = operationData[1]
            self[f](self, unpack(operationData, 2))

          if self.ppu_sync then self.ppu.sync(self.clk)  end
          asd = asd+1
          if asd > 30 then
            error "asd"
          end
        until self.clk < self.clk_target
        self:do_clock()
    until self.clk < self.clk_frame
    end

    CPU.ADDRESSING_MODES = {
      ctl= {"imm",   "zpg", "imm", "abs", UNDEFINED,    "zpg_x", UNDEFINED,    "abs_x"},
      rmw= {"imm",   "zpg", "imm", "abs", UNDEFINED,    "zpg_y", UNDEFINED,    "abs_y"},
      alu= {"ind_x", "zpg", "imm", "abs", "ind_y", "zpg_x", "abs_y", "abs_x"},
      uno= {"ind_x", "zpg", "imm", "abs", "ind_y", "zpg_y", "abs_y", "abs_y"},
    }
    CPU.DISPATCH = {}
    local function op(opcodes, args)
        for _,opcode in ipairs(opcodes) do
      local send_args
            if type(args) == "table" then
                if (args[1] == "r_op" or args[1] == "w_op" or args[1] == "rw_op") then
                    local kind, ope, mode = args[1], args[2], args[3]
                    mode = CPU.ADDRESSING_MODES[mode][bit.band(bit.rshift(opcode, 2), 7)+1]
                    send_args = {kind, ope, mode}
                    if kind ~= "r_op" then
                        send_args[#send_args+1]= (mode:sub(1, 3) == "zpg" and "store_zpg" or "store_mem")
                    end
                else
                    send_args = args
                end
            else
            send_args = {args}
            end
            CPU.DISPATCH[opcode] = send_args
        end
    end

    -- load instructions
    op({0xa9, 0xa5, 0xb5, 0xad, 0xbd, 0xb9, 0xa1, 0xb1},       {"r_op", "_lda", "alu"})
    op({0xa2, 0xa6, 0xb6, 0xae, 0xbe},                         {"r_op", "_ldx", "rmw"})
    op({0xa0, 0xa4, 0xb4, 0xac, 0xbc},                         {"r_op", "_ldy", "ctl"})

    -- store instructions
    op({0x85, 0x95, 0x8d, 0x9d, 0x99, 0x81, 0x91},             {"w_op", "_sta", "alu"})
    op({0x86, 0x96, 0x8e},                                     {"w_op", "_stx", "rmw"})
    op({0x84, 0x94, 0x8c},                                     {"w_op", "_sty", "ctl"})

    -- transfer instructions
    op({0xaa},                                                 "_tax")
    op({0xa8},                                                 "_tay")
    op({0x8a},                                                 "_txa")
    op({0x98},                                                 "_tya")

    -- flow control instructions
    op({0x4c},                                                 "_jmp_a")
    op({0x6c},                                                 "_jmp_i")
    op({0x20},                                                 "_jsr")
    op({0x60},                                                 "_rts")
    op({0x40},                                                 "_rti")
    op({0xd0},                                                 "_bne")
    op({0xf0},                                                 "_beq")
    op({0x30},                                                 "_bmi")
    op({0x10},                                                 "_bpl")
    op({0xb0},                                                 "_bcs")
    op({0x90},                                                 "_bcc")
    op({0x70},                                                 "_bvs")
    op({0x50},                                                 "_bvc")

    -- math operations
    op({0x69, 0x65, 0x75, 0x6d, 0x7d, 0x79, 0x61, 0x71},       {"r_op", "_adc", "alu"})
    op({0xe9, 0xeb, 0xe5, 0xf5, 0xed, 0xfd, 0xf9, 0xe1, 0xf1}, {"r_op", "_sbc", "alu"})

    -- logical operations
    op({0x29, 0x25, 0x35, 0x2d, 0x3d, 0x39, 0x21, 0x31},       {"r_op", "_and", "alu"})
    op({0x09, 0x05, 0x15, 0x0d, 0x1d, 0x19, 0x01, 0x11},       {"r_op", "_ora", "alu"})
    op({0x49, 0x45, 0x55, 0x4d, 0x5d, 0x59, 0x41, 0x51},       {"r_op", "_eor", "alu"})
    op({0x24, 0x2c},                                           {"r_op", "_bit", "alu"})
    op({0xc9, 0xc5, 0xd5, 0xcd, 0xdd, 0xd9, 0xc1, 0xd1},       {"r_op", "_cmp", "alu"})
    op({0xe0, 0xe4, 0xec},                                     {"r_op", "_cpx", "rmw"})
    op({0xc0, 0xc4, 0xcc},                                     {"r_op", "_cpy", "rmw"})

    -- shift operations
    op({0x0a},                                                 {"a_op", "_asl"})
    op({0x06, 0x16, 0x0e, 0x1e},                               {"rw_op", "_asl", "alu"})
    op({0x4a},                                                 {"a_op", "_lsr"})
    op({0x46, 0x56, 0x4e, 0x5e},                               {"rw_op", "_lsr", "alu"})
    op({0x2a},                                                 {"a_op", "_rol"})
    op({0x26, 0x36, 0x2e, 0x3e},                               {"rw_op", "_rol", "alu"})
    op({0x6a},                                                 {"a_op", "_ror"})
    op({0x66, 0x76, 0x6e, 0x7e},                               {"rw_op", "_ror", "alu"})

    -- increment and decrement operations
    op({0xc6, 0xd6, 0xce, 0xde},                               {"rw_op", "_dec", "alu"})
    op({0xe6, 0xf6, 0xee, 0xfe},                               {"rw_op", "_inc", "alu"})
    op({0xca},                                                 "_dex")
    op({0x88},                                                 "_dey")
    op({0xe8},                                                 "_inx")
    op({0xc8},                                                 "_iny")

    -- flags instructions
    op({0x18},                                                 "_clc")
    op({0x38},                                                 "_sec")
    op({0xd8},                                                 "_cld")
    op({0xf8},                                                 "_sed")
    op({0x58},                                                 "_cli")
    op({0x78},                                                 "_sei")
    op({0xb8},                                                 "_clv")

    -- stack operations
    op({0x48},                                                 "_pha")
    op({0x08},                                                 "_php")
    op({0x68},                                                 "_pla")
    op({0x28},                                                 "_plp")
    op({0xba},                                                 "_tsx")
    op({0x9a},                                                 "_txs")

    -- undocumented instructions, rarely used
    op({0x0b, 0x2b},                                           {"r_op", "_anc", "uno"})
    op({0x8b},                                                 {"r_op", "_ane", "uno"})
    op({0x6b},                                                 {"r_op", "_arr", "uno"})
    op({0x4b},                                                 {"r_op", "_asr", "uno"})
    op({0xc7, 0xd7, 0xc3, 0xd3, 0xcf, 0xdf, 0xdb},             {"rw_op", "_dcp", "alu"})
    op({0xe7, 0xf7, 0xef, 0xff, 0xfb, 0xe3, 0xf3},             {"rw_op", "_isb", "alu"})
    op({0xbb},                                                 {"r_op", "_las", "uno"})
    op({0xa7, 0xb7, 0xaf, 0xbf, 0xa3, 0xb3},                   {"r_op", "_lax", "uno"})
    op({0xab},                                                 {"r_op", "_lxa", "uno"})
    op({0x27, 0x37, 0x2f, 0x3f, 0x3b, 0x23, 0x33},             {"rw_op", "_rla", "alu"})
    op({0x67, 0x77, 0x6f, 0x7f, 0x7b, 0x63, 0x73},             {"rw_op", "_rra", "alu"})
    op({0x87, 0x97, 0x8f, 0x83},                               {"w_op", "_sax", "uno"})
    op({0xcb},                                                 {"r_op", "_sbx", "uno"})
    op({0x9f, 0x93},                                           {"w_op", "_sha", "uno"})
    op({0x9b},                                                 {"w_op", "_shs", "uno"})
    op({0x9e},                                                 {"w_op", "_shx", "rmw"})
    op({0x9c},                                                 {"w_op", "_shy", "ctl"})
    op({0x07, 0x17, 0x0f, 0x1f, 0x1b, 0x03, 0x13},             {"rw_op", "_slo", "alu"})
    op({0x47, 0x57, 0x4f, 0x5f, 0x5b, 0x43, 0x53},             {"rw_op", "_sre", "alu"})

    -- nops
    op({0x1a, 0x3a, 0x5a, 0x7a, 0xda, 0xea, 0xfa},             {"no_op", "_nop", 0, 2})
    op({0x80, 0x82, 0x89, 0xc2, 0xe2},                         {"no_op", "_nop", 1, 2})
    op({0x04, 0x44, 0x64},                                     {"no_op", "_nop", 1, 3})
    op({0x14, 0x34, 0x54, 0x74, 0xd4, 0xf4},                   {"no_op", "_nop", 1, 4})
    op({0x0c},                                                 {"no_op", "_nop", 2, 4})
    op({0x1c, 0x3c, 0x5c, 0x7c, 0xdc, 0xfc},                   {"r_op", "_nop", "ctl"})

    -- interrupts
    op({0x00},                                                 "_brk")
    op({0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xb2, 0xd2, 0xf2}, "_jam")

    --[[
    --------------------------------------------------------------------------------------------------------------------
    -- optimized core generator
    class OptimizedCodeBuilder
      include CodeOptimizationHelper

      OPTIONS = [:method_inlining, :constant_inlining, :ivar_localization, :trivial_branches]

      LOCALIZE_IVARS = [:self.addr, :self.data, :self._a, :self._x, :self._y, :self._pc, :self._sp, :self.fetch, :self.s

      function CPU:build
        depends(:ivar_localization, :method_inlining)

        mdefs = parse_method_definitions(__FILE__)
        code = build_loop(mdefs)

        -- optimize!
        code = cpu_expand_methods(code, mdefs) if self.method_inlining
        code = remove_trivial_branches(code) if self.trivial_branches
        code = expand_constants(code) if self.constant_inlining
        code = localize_instance_variables(code, LOCALIZE_IVARS) if self.ivar_localization

        gen(
          "function CPU:self.run",
          indent(2, code),
          "end",
        )
      end

      -- generate a main code
      function CPU:build_loop(mdefs)
        dispatch = gen(
          "case self.opcode",
          *DISPATCH.map.with_index do |args, opcode|
            if args.size > 1
              mhd, instr, = args
              code = expand_inline_methods("--{ mhd }(--{ args.drop(1).join(", ") })", mhd, mdefs[mhd])
              code = code.gsub(/send\((\w+), (.*?)\)/) { "--{ $1 }(--{ $2 })" }
              code = code.gsub(/send\((\w+)\)/) { $1 }
              code = code[1..-2].split("; ")
            else
              instr = code = args[0]
            end
            "when 0x%02x -- --{ instr }\n" % opcode + indent(2, gen(*code))
          end,
          "end"
        )
        main = mdefs[:run].body.sub("self.conf.loglevel >= 3") { self.loglevel >= 3 }
        main.sub(/^ *send.*\n/) { indent(4, dispatch) }
      end

      -- inline method calls
      function CPU:cpu_expand_methods(code, mdefs)
        code = expand_methods(code, mdefs, mdefs.keys.grep(/^_/))
        [
          [:_adc, :_sbc, :_cmp, :store_mem, :store_zpg],
          [:imm, :abs, :zpg, :abs_x, :abs_y, :zpg_x, :zpg_y, :ind_x, :ind_y],
          [:abs_reg, :zpg_reg],
          [:read_write],
          [:do_clock],
          [:do_isr],
          [:branch, :push16],
          [:push8],
        ].each do |meths|
          code = expand_methods(code, mdefs, meths)
        end
        [:fetch, :peek16, :store, :pull16, :pull8].each do |meth|
          code = expand_inline_methods(code, meth, mdefs[meth])
        end
        code
      end

      -- inline constants
      function CPU:expand_constants(handlers)
        handlers = handlers.gsub(/CLK_(\d+)/) { eval($&) }
        handlers = handlers.gsub(/NES.FOREVER_CLOCK/) { "0xffffffff" }
        handlers
end
end
]]

return CPU