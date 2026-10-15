package linux

// linux/if.h and linux/sockios.h
IFNAMSIZ    :: 16
SIOCGIFNAME  :: 0x8910
SIOCGIFINDEX :: 0x8933

If_Map :: struct {
	mem_start: uint,
	mem_end:   uint,
	base_addr: u16,
	irq:       u8,
	dma:       u8,
	port:      u8,
}

If_Settings :: struct {
	type:     u32,
	size:     u32,
	ifs_ifsu: rawptr,
}

If_Req :: struct {
	ifr_name: [IFNAMSIZ]u8,
	ifr_ifru: struct #raw_union {
		ifru_addr:      Sock_Addr,
		ifru_dstaddr:   Sock_Addr,
		ifru_broadaddr: Sock_Addr,
		ifru_netmask:   Sock_Addr,
		ifru_hwaddr:    Sock_Addr,
		ifru_flags:    i16,
		ifru_ivalue:   i32,
		ifru_mtu:      i32,
		ifru_map:      If_Map,
		ifru_slave:    [IFNAMSIZ]u8,
		ifru_newname:  [IFNAMSIZ]u8,
		ifru_data:     rawptr,
		ifru_settings: If_Settings,
	},
}

#assert(offset_of(If_Req, ifr_ifru) == IFNAMSIZ)
when ODIN_ARCH == .amd64 {
	#assert(size_of(If_Map) == 24)
	#assert(size_of(If_Req) == 40)
	#assert(align_of(If_Req) == 8)
}
