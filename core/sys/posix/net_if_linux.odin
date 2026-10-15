#+build linux
package posix

import "core:c"
import "core:sys/linux"

#assert(IF_NAMESIZE == linux.IFNAMSIZ)

// Returns the interface index, or zero and sets errno on failure.
if_nametoindex :: proc "c" (name: cstring) -> c.uint {
	if name == nil {
		set_errno(.EFAULT)
		return 0
	}
	request: linux.If_Req
	bytes := ([^]u8)(name)
	length := 0
	for length < IF_NAMESIZE && bytes[length] != 0 {
		request.ifr_name[length] = bytes[length]
		length += 1
	}
	if length == IF_NAMESIZE {
		set_errno(.ENODEV)
		return 0
	}
	fd, err := linux.socket(.INET, .DGRAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE {
		set_errno(Errno(err))
		return 0
	}
	defer linux.close(fd)
	_, ioctl_err := linux.ioctl(fd, linux.SIOCGIFINDEX, uintptr(&request))
	if ioctl_err != .NONE {
		set_errno(Errno(ioctl_err))
		return 0
	}
	return c.uint(request.ifr_ifru.ifru_ivalue)
}

// Writes the interface name to an IF_NAMESIZE-byte buffer and returns it.
// Returns nil and sets errno on failure.
if_indextoname :: proc "c" (ifindex: c.uint, ifname: [^]byte) -> cstring {
	if ifname == nil {
		set_errno(.EFAULT)
		return nil
	}
	request: linux.If_Req
	request.ifr_ifru.ifru_ivalue = i32(ifindex)
	fd, err := linux.socket(.INET, .DGRAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE {
		set_errno(Errno(err))
		return nil
	}
	defer linux.close(fd)
	_, ioctl_err := linux.ioctl(fd, linux.SIOCGIFNAME, uintptr(&request))
	if ioctl_err != .NONE {
		if ioctl_err == .ENODEV {
			ioctl_err = .ENXIO
		}
		set_errno(Errno(ioctl_err))
		return nil
	}
	for i in 0..<IF_NAMESIZE {
		ifname[i] = request.ifr_name[i]
	}
	ifname[IF_NAMESIZE-1] = 0
	return cstring(ifname)
}
