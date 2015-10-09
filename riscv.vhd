library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;
library work;
use work.rv_components.all;
use work.utils.all;

entity riscV is

  generic (
    REGISTER_SIZE : integer := 32;
    RESET_VECTOR  : natural := 16#00000200#);

  port(clk   : in std_logic;
       reset : in std_logic;

       --conduit end point
       coe_to_host         : out std_logic_vector(REGISTER_SIZE -1 downto 0);
       coe_from_host       : in  std_logic_vector(REGISTER_SIZE -1 downto 0);
       coe_program_counter : out std_logic_vector(REGISTER_SIZE -1 downto 0);

--avalon master bus
       avm_data_address       : out std_logic_vector(REGISTER_SIZE-1 downto 0);
       avm_data_byteenable    : out std_logic_vector(REGISTER_SIZE/8 -1 downto 0);
       avm_data_read          : out std_logic;
       avm_data_readdata      : in  std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => 'X');
       avm_data_response      : in  std_logic_vector(1 downto 0)               := (others => 'X');
       avm_data_write         : out std_logic;
       avm_data_writedata     : out std_logic_vector(REGISTER_SIZE-1 downto 0);
       avm_data_lock          : out std_logic;
       avm_data_waitrequest   : in  std_logic                                  := '0';
       avm_data_readdatavalid : in  std_logic                                  := '0';

       --avalon master bus
       avm_instruction_address       : out std_logic_vector(REGISTER_SIZE-1 downto 0);
       avm_instruction_byteenable    : out std_logic_vector(REGISTER_SIZE/8 -1 downto 0);
       avm_instruction_read          : out std_logic;
       avm_instruction_readdata      : in  std_logic_vector(REGISTER_SIZE-1 downto 0) := (others => 'X');
       avm_instruction_response      : in  std_logic_vector(1 downto 0)               := (others => 'X');
       avm_instruction_write         : out std_logic;
       avm_instruction_writedata     : out std_logic_vector(REGISTER_SIZE-1 downto 0);
       avm_instruction_lock          : out std_logic;
       avm_instruction_waitrequest   : in  std_logic                                  := '0';
       avm_instruction_readdatavalid : in  std_logic                                  := '0'

       );

end entity riscV;

architecture rtl of riscV is
  constant REGISTER_NAME_SIZE  : integer := 5;
  constant INSTRUCTION_SIZE    : integer := 32;
  constant SIGN_EXTENSION_SIZE : integer := 20;


  --signals going int fetch

  signal pc_corr_en   : std_logic;
  signal pc_corr      : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal if_stall_in  : std_logic;
  signal if_valid_out : std_logic;


  --signals going into decode
  signal d_instr        : std_logic_vector(INSTRUCTION_SIZE -1 downto 0);
  signal d_pc           : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal d_next_pc      : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal d_valid        : std_logic;
  signal d_valid_out    : std_logic;
  signal decode_stalled : std_logic;

  signal wb_data : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal wb_sel  : std_logic_vector(REGISTER_NAME_SIZE-1 downto 0);
  signal wb_en   : std_logic;

  --signals going into execute
  signal e_instr     : std_logic_vector(INSTRUCTION_SIZE -1 downto 0);
  signal e_pc        : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal e_next_pc   : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal e_valid     : std_logic;
  signal e_readvalid : std_logic;

  signal execute_stalled : std_logic;
  signal rs1_data        : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal rs2_data        : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal sign_extension  : std_logic_vector(REGISTER_SIZE-12-1 downto 0);

  signal pipeline_flush : std_logic;


  signal data_address    : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal data_byte_en    : std_logic_vector(REGISTER_SIZE/8 -1 downto 0);
  signal data_write_en   : std_logic;
  signal data_read_en    : std_logic;
  signal data_write_data : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal data_read_data  : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal data_wait       : std_logic;

  signal instr_address : std_logic_vector(REGISTER_SIZE-1 downto 0);
  signal instr_data    : std_logic_vector(INSTRUCTION_SIZE-1 downto 0);

  signal instr_read_wait : std_logic;
  signal instr_read_en   : std_logic;
  signal instr_readvalid : std_logic;

  --calculate this for interupts
  signal next_valid_ex_pc : std_logic_vector(INSTRUCTION_SIZE-1 downto 0);

begin  -- architecture rtl
  pipeline_flush      <= pc_corr_en;
  coe_program_counter <= d_pc;

  if_stall_in <= execute_stalled or decode_stalled;
  instr_fetch : component instruction_fetch
    generic map (
      REGISTER_SIZE    => REGISTER_SIZE,
      INSTRUCTION_SIZE => INSTRUCTION_SIZE,
      RESET_VECTOR     => RESET_VECTOR)
    port map (
      clk        => clk,
      reset      => reset,
      stall      => if_stall_in,
      pc_corr    => pc_corr,
      pc_corr_en => pc_corr_en,

      instr_out       => d_instr,
      pc_out          => d_pc,
      next_pc_out     => d_next_pc,
      valid_instr_out => if_valid_out,
      read_address    => instr_address,
      read_en         => instr_read_en,
      read_data       => instr_data,
      read_wait       => instr_read_wait,
      read_datavalid  => instr_readvalid);


  d_valid     <= if_valid_out and not pipeline_flush;
  D : component decode
    generic map(
      REGISTER_SIZE       => REGISTER_SIZE,
      REGISTER_NAME_SIZE  => REGISTER_NAME_SIZE,
      INSTRUCTION_SIZE    => INSTRUCTION_SIZE,
      SIGN_EXTENSION_SIZE => SIGN_EXTENSION_SIZE)
    port map(
      clk            => clk,
      reset          => reset,
      stall          => execute_stalled,
      instruction    => d_instr,
      valid_input    => d_valid,
      --writeback ,signals
      wb_sel         => wb_sel,
      wb_data        => wb_data,
      wb_enable      => wb_en,
      --output sig,nals
      rs1_data       => rs1_data,
      rs2_data       => rs2_data,
      sign_extension => sign_extension,
      --inputs jus,t for carrying to next pipeline stage
      pc_next_in     => d_next_pc,
      pc_curr_in     => d_pc,
      instr_in       => d_instr,
      pc_next_out    => e_next_pc,
      pc_curr_out    => e_pc,
      instr_out      => e_instr,
      stall_out      => decode_stalled,
      valid_output   => d_valid_out);

  e_valid <= d_valid_out and not pipeline_flush;
  X : component execute
    generic map (
      REGISTER_SIZE       => REGISTER_SIZE,
      REGISTER_NAME_SIZE  => REGISTER_NAME_SIZE,
      INSTRUCTION_SIZE    => INSTRUCTION_SIZE,
      SIGN_EXTENSION_SIZE => SIGN_EXTENSION_SIZE,
      RESET_VECTOR        => RESET_VECTOR)
    port map (
      clk             => clk,
      reset           => reset,
      valid_input     => e_valid,
      pc_next         => e_next_pc,
      pc_current      => e_pc,
      instruction     => e_instr,
      rs1_data        => rs1_data,
      rs2_data        => rs2_data,
      sign_extension  => sign_extension,
      wb_sel          => wb_sel,
      wb_data         => wb_data,
      wb_en           => wb_en,
      predict_corr    => pc_corr,
      predict_corr_en => pc_corr_en,
      stall_pipeline  => execute_stalled,
      from_host       => coe_from_host,
      to_host         => coe_to_host,
      --memory lines
      address         => data_address,
      byte_en         => data_byte_en,
      write_en        => data_write_en,
      read_en         => data_read_en,
      write_data      => data_write_data,
      read_data       => data_read_data,
      waitrequest     => data_wait,
      datavalid       => e_readvalid);


  MEM : component memory_system
    generic map (
      REGISTER_SIZE     => REGISTER_SIZE,
      DUAL_PORTED_INSTR => false)
    port map (
      clk             => clk,
      instr_addr      => instr_address,
      data_addr       => data_address,
      data_we         => data_write_en,
      data_be         => data_byte_en,
      data_wdata      => data_write_data,
      data_rdata      => data_read_data,
      instr_rdata     => instr_data,
      data_read_en    => data_read_en,
      instr_read_en   => instr_read_en,
      instr_wait      => instr_read_wait,
      data_wait       => data_wait,
      instr_readvalid => instr_readvalid,
      data_readvalid  => e_readvalid,

      --avalon mm bus
      data_av_address       => avm_data_address,
      data_av_byteenable    => avm_data_byteenable,
      data_av_read          => avm_data_read,
      data_av_readdata      => avm_data_readdata,
      data_av_response      => avm_data_response,
      data_av_write         => avm_data_write,
      data_av_writedata     => avm_data_writedata,
      data_av_lock          => avm_data_lock,
      data_av_waitrequest   => avm_data_waitrequest,
      data_av_readdatavalid => avm_data_readdatavalid,

      --avalon mm bus
      instr_av_address       => avm_instruction_address,
      instr_av_byteenable    => avm_instruction_byteenable,
      instr_av_read          => avm_instruction_read,
      instr_av_readdata      => avm_instruction_readdata,
      instr_av_response      => avm_instruction_response,
      instr_av_write         => avm_instruction_write,
      instr_av_writedata     => avm_instruction_writedata,
      instr_av_lock          => avm_instruction_lock,
      instr_av_waitrequest   => avm_instruction_waitrequest,
      instr_av_readdatavalid => avm_instruction_readdatavalid);


  -- during reset, the next executed instruction will be at reset target
  -- if not in reset: if pc_corr_en, all pipeline stages will be flushed and
  -- pc_corr will be the next executed instruction. if neither of these conditions
  -- are true the next instruction will be the the one that is currently being
  -- decoded.
  -- It is possible that the instruction in the deode stage is not valid, but
  -- the pc in d_pc always points to the correct instruction, see instruction_fetch.vhd
  -- if you need to see.

  next_valid_ex_pc <= (others => 'X') when reset = '1' else
                      pc_corr when pc_corr_en = '1' else
                      d_pc;

end architecture rtl;
