-------------------------------------------------------------------------------
-- Company    : SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
-- Description: Ring Buffer Engine
-------------------------------------------------------------------------------
-- Data Format Definitions: https://docs.google.com/spreadsheets/d/1EdbgGU8szjVyl3ZKYMZXtHn6p-MUJLZG59m6oqJuD-0/edit?usp=sharing
-------------------------------------------------------------------------------
-- This file is part of 'nexo-daq-ring-buffer'.
-- It is subject to the license terms in the LICENSE.txt file found in the
-- top-level directory of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of 'nexo-daq-ring-buffer', including this file,
-- may be copied, modified, propagated, or distributed except according to
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library surf;
use surf.StdRtlPkg.all;
use surf.AxiLitePkg.all;
use surf.AxiStreamPkg.all;
use surf.SsiPkg.all;
use surf.AxiPkg.all;
use surf.AxiDmaPkg.all;

library nexo_daq_ring_buffer;
use nexo_daq_ring_buffer.RingBufferPkg.all;

library nexo_daq_trigger_decision;
use nexo_daq_trigger_decision.TriggerDecisionPkg.all;

entity RingBufferEngine is
   generic (
      TPD_G            : time    := 1 ns;
      SIMULATION_G     : boolean := false;
      ADC_TYPE_G       : boolean := true;  -- True: 12-bit ADC for CHARGE, False: 10-bit ADC for PHOTON
      DDR_DIMM_INDEX_G : natural := 0;
      STREAM_INDEX_G   : natural := 0);
   port (
      -- Clock and Reset
      clk             : in  sl;
      rst             : in  sl;
      -- ADC Stream Interface
      adcMaster       : in  AxiStreamMasterType;
      adcSlave        : out AxiStreamSlaveType;
      -- Trigger Decision Interface
      trigRdMaster    : in  AxiStreamMasterType;
      trigRdSlave     : out AxiStreamSlaveType;
      -- Compression Interface
      compMaster      : out AxiStreamMasterType;
      compSlave       : in  AxiStreamSlaveType;
      -- AXI4 Interface
      axiWriteMaster  : out AxiWriteMasterType;
      axiWriteSlave   : in  AxiWriteSlaveType;
      axiReadMaster   : out AxiReadMasterType;
      axiReadSlave    : in  AxiReadSlaveType;
      -- AXI-Lite Interface
      axilReadMaster  : in  AxiLiteReadMasterType;
      axilReadSlave   : out AxiLiteReadSlaveType;
      axilWriteMaster : in  AxiLiteWriteMasterType;
      axilWriteSlave  : out AxiLiteWriteSlaveType);
end RingBufferEngine;

architecture rtl of RingBufferEngine is

   type RegType is record
      enable         : sl;
      cntRst         : sl;
      awcache        : slv(3 downto 0);
      arcache        : slv(3 downto 0);
      dropFrameCnt   : slv(31 downto 0);
      eofeEventCnt   : slv(31 downto 0);
      -- AXI-Lite
      axilReadSlave  : AxiLiteReadSlaveType;
      axilWriteSlave : AxiLiteWriteSlaveType;
   end record;
   constant REG_INIT_C : RegType := (
      enable         => '1',
      cntRst         => '0',
      awcache        => "0010",         -- Merge-able writes
      arcache        => "1111",
      dropFrameCnt   => (others => '0'),
      eofeEventCnt   => (others => '0'),
      -- AXI-Lite
      axilReadSlave  => AXI_LITE_READ_SLAVE_INIT_C,
      axilWriteSlave => AXI_LITE_WRITE_SLAVE_INIT_C);

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

   signal dropFrame : sl;
   signal eofeEvent : sl;

   signal wrReq : AxiWriteDmaReqType;
   signal wrAck : AxiWriteDmaAckType;

   signal rdReq : AxiReadDmaReqType;
   signal rdAck : AxiReadDmaAckType;

   signal writeMaster : AxiStreamMasterType;
   signal writeSlave  : AxiStreamSlaveType;

   signal readMaster : AxiStreamMasterType;
   signal readSlave  : AxiStreamSlaveType;

   signal trigHdrMaster : AxiStreamMasterType;
   signal trigHdrSlave  : AxiStreamSlaveType;

begin

   comb : process (axilReadMaster, axilWriteMaster, dropFrame, eofeEvent, r,
                   rst) is
      variable v      : RegType;
      variable axilEp : AxiLiteEndPointType;
   begin
      -- Latch the current value
      v := r;

      -- Reset strobes
      v.cntRst := '0';

      -- Check for dropped frame flag
      if (dropFrame = '1') then
         -- Increment the error counter
         v.dropFrameCnt := r.dropFrameCnt + 1;
      end if;

      -- Check for eofeEvent flag
      if (eofeEvent = '1') then
         -- Increment the error counter
         v.eofeEventCnt := r.eofeEventCnt + 1;
      end if;

      -- Check for counter reset
      if (r.cntRst = '1') then
         v.dropFrameCnt := (others => '0');
         v.eofeEventCnt := (others => '0');
      end if;

      --------------------------------------------------------------------------------
      -- AXI-Lite Register Transactions
      --------------------------------------------------------------------------------

      -- Determine the transaction type
      axiSlaveWaitTxn(axilEp, axilWriteMaster, axilReadMaster, v.axilWriteSlave, v.axilReadSlave);

      -- Map the read registers
      axiSlaveRegisterR(axilEp, x"00", 0, toSlv(STREAM_INDEX_G, 4));
      axiSlaveRegisterR(axilEp, x"00", 4, toSlv(DDR_DIMM_INDEX_G, 4));
      axiSlaveRegisterR(axilEp, x"00", 8, ite(ADC_TYPE_G, '1', '0'));
      axiSlaveRegisterR(axilEp, x"00", 12, ite(SIMULATION_G, '1', '0'));

      axiSlaveRegisterR(axilEp, x"04", 0, r.dropFrameCnt);
      axiSlaveRegisterR(axilEp, x"08", 0, r.eofeEventCnt);

      axiSlaveRegister (axilEp, x"80", 0, v.awcache);
      axiSlaveRegister (axilEp, x"80", 4, v.arcache);

      axiSlaveRegister (axilEp, x"84", 0, v.enable);
      axiSlaveRegister (axilEp, x"FC", 0, v.cntRst);

      -- Closeout the transaction
      axiSlaveDefault(axilEp, v.axilWriteSlave, v.axilReadSlave, AXI_RESP_DECERR_C);

      --------------------------------------------------------------------------------

      -- Outputs
      axilWriteSlave <= r.axilWriteSlave;
      axilReadSlave  <= r.axilReadSlave;

      -- Reset
      if (rst = '1') then
         v := REG_INIT_C;
      end if;

      -- Register the variable for next clock cycle
      rin <= v;

   end process comb;

   seq : process (clk) is
   begin
      if rising_edge(clk) then
         r <= rin after TPD_G;
      end if;
   end process seq;

   ------------
   -- Write FSM
   ------------
   U_WriteFsm : entity nexo_daq_ring_buffer.RingBufferWriteFsm
      generic map (
         TPD_G          => TPD_G,
         SIMULATION_G   => SIMULATION_G,
         ADC_TYPE_G     => ADC_TYPE_G,
         STREAM_INDEX_G => STREAM_INDEX_G)
      port map (
         -- Control/Monitor Interface
         enable      => r.enable,
         dropFrame   => dropFrame,
         -- Clock and Reset
         clk         => clk,
         rst         => rst,
         -- Compression Inbound Interface
         adcMaster   => adcMaster,
         adcSlave    => adcSlave,
         -- DMA Write Interface
         wrReq       => wrReq,
         wrAck       => wrAck,
         writeMaster => writeMaster,
         writeSlave  => writeSlave);

   --------------------------------
   -- DMA Engine for the DDR Memory
   --------------------------------
   U_DMA : entity nexo_daq_ring_buffer.RingBufferDma
      generic map (
         TPD_G      => TPD_G,
         ADC_TYPE_G => ADC_TYPE_G)
      port map (
         -- Clock and Reset
         clk            => clk,
         rst            => rst,
         -- Inbound AXI Stream Interface
         awcache        => r.awcache,
         wrReq          => wrReq,
         wrAck          => wrAck,
         wrMaster       => writeMaster,
         wrSlave        => writeSlave,
         -- Outbound AXI Stream Interface
         arcache        => r.arcache,
         rdReq          => rdReq,
         rdAck          => rdAck,
         rdMaster       => readMaster,
         rdSlave        => readSlave,
         -- AXI4 Interface
         axiWriteMaster => axiWriteMaster,
         axiWriteSlave  => axiWriteSlave,
         axiReadMaster  => axiReadMaster,
         axiReadSlave   => axiReadSlave);

   ------------
   -- Read FSM
   ------------
   U_ReadFsm : entity nexo_daq_ring_buffer.RingBufferReadFsm
      generic map (
         TPD_G            => TPD_G,
         SIMULATION_G     => SIMULATION_G,
         ADC_TYPE_G       => ADC_TYPE_G,
         DDR_DIMM_INDEX_G => DDR_DIMM_INDEX_G,
         STREAM_INDEX_G   => STREAM_INDEX_G)
      port map (
         -- Control/Monitor Interface
         enable        => r.enable,
         eofeEvent     => eofeEvent,
         -- Clock and Reset
         clk           => clk,
         rst           => rst,
         -- DMA Read Interface
         rdReq         => rdReq,
         rdAck         => rdAck,
         -- Trigger Decision Interface
         trigRdMaster  => trigRdMaster,
         trigRdSlave   => trigRdSlave,
         -- Trigger Header Interface
         trigHdrMaster => trigHdrMaster,
         trigHdrSlave  => trigHdrSlave);

   ----------------------------
   -- Insert the Trigger header
   ----------------------------
   U_InsertTrigHdr : entity nexo_daq_ring_buffer.RingBufferInsertTrigHdr
      generic map (
         TPD_G => TPD_G)
      port map (
         -- Clock and Reset
         clk           => clk,
         rst           => rst,
         -- Trigger Header
         trigHdrMaster => trigHdrMaster,
         trigHdrSlave  => trigHdrSlave,
         -- Slave Port
         sAxisMaster   => readMaster,
         sAxisSlave    => readSlave,
         -- Master Port
         mAxisMaster   => compMaster,
         mAxisSlave    => compSlave);

end rtl;
