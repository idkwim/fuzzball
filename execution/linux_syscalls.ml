(*
 Owned and copyright BitBlaze, 2009-2010. All rights reserved.
 Do not copy, disclose, or distribute without explicit written
 permission.
*)

module V = Vine;;

open Concrete_domain;;
open Exec_exceptions;;
open Exec_options;;
open Fragment_machine;;

let linux_initial_break = ref None

let linux_setup_tcb_seg (fm : fragment_machine) new_ent new_gdt base limit =
  let store_byte base idx v =
    let addr = Int64.add base (Int64.of_int idx) in
      fm#store_byte_conc addr (Int64.to_int v)
  in
  let new_gs = (new_ent lsl 3) lor 3 in
  let descr = Int64.add new_gdt (Int64.of_int (new_ent lsl 3)) in
    fm#set_word_var R_GDT new_gdt;
    fm#set_short_var R_GS new_gs;
    store_byte descr 0 (Int64.logand limit 0xffL);
    store_byte descr 1 (Int64.logand 
			  (Int64.shift_right limit 8) 0xffL);
    store_byte descr 2 (Int64.logand base 0xffL);
    store_byte descr 3 (Int64.logand
			  (Int64.shift_right base 8) 0xffL);
    store_byte descr 4 (Int64.logand
			  (Int64.shift_right base 16) 0xffL);
    store_byte descr 5 0xf3L; (* pres., ring 3, app, r/w a *)
    store_byte descr 6 (Int64.logor 0xc0L
			  (Int64.shift_right limit 16));
    (* page-gran limit, 32-bit, high nibble of limit *)
    store_byte descr 7 (Int64.logand
			  (Int64.shift_right base 24) 0xffL)

class linux_special_handler (fm : fragment_machine) =
  let put_reg = fm#set_word_var in
  let load_word addr =
    fm#load_word_concretize addr !opt_measure_influence_syscall_args
      "syscall arg"
  in
  let load_short addr =
    fm#load_short_concretize addr !opt_measure_influence_syscall_args
      "syscall arg"
  in
  let load_byte addr =
    fm#load_byte_concretize addr !opt_measure_influence_syscall_args
      "syscall arg"
  in
  let lea base i step off =
    Int64.add base (Int64.add (Int64.mul (Int64.of_int i) (Int64.of_int step))
		      (Int64.of_int off)) in
  let store_word base idx v =
    let addr = Int64.add base (Int64.of_int idx) in
      fm#store_word_conc addr v
  in
  let zero_region base len =
    for i = 0 to len -1 do fm#store_byte_idx base i 0 done
  in
object(self)
  val unix_fds = 
    let a = Array.make 1024 None in
      Array.set a 0 (Some Unix.stdin);
      Array.set a 1 (Some Unix.stdout);
      Array.set a 2 (Some Unix.stderr);
      a

  method fresh_fd () =
    let rec loop i = match unix_fds.(i) with
      | None -> i
      | Some _ -> loop (i + 1)
    in loop 0

  method get_fd vt_fd =
    match unix_fds.(vt_fd) with
      | Some fd -> fd
      | None -> raise
	  (Unix.Unix_error(Unix.EBADF, "Bad (virtual) file handle", ""))

  method errno err =
    match err with
      | Unix.E2BIG -> 7
      | Unix.EACCES -> 13
      | Unix.EAGAIN -> 11
      | Unix.EBADF -> 9
      | Unix.EBUSY -> 16
      | Unix.ECHILD -> 10
      | Unix.EDEADLK -> 35
      | Unix.EDOM -> 33
      | Unix.EEXIST -> 17
      | Unix.EFAULT -> 14
      | Unix.EFBIG -> 27
      | Unix.EINTR -> 4
      | Unix.EINVAL -> 22
      | Unix.EIO -> 5
      | Unix.EISDIR -> 21
      | Unix.EMFILE -> 24
      | Unix.EMLINK -> 31
      | Unix.ENAMETOOLONG -> 36
      | Unix.ENFILE -> 23
      | Unix.ENODEV -> 19
      | Unix.ENOENT -> 2
      | Unix.ENOEXEC -> 8
      | Unix.ENOLCK -> 37
      | Unix.ENOMEM -> 12
      | Unix.ENOSPC -> 28
      | Unix.ENOSYS -> 38
      | Unix.ENOTDIR -> 20
      | Unix.ENOTEMPTY -> 39
      | Unix.ENOTTY -> 25
      | Unix.ENXIO -> 6
      | Unix.EPERM -> 1
      | Unix.EPIPE -> 32
      | Unix.ERANGE -> 34
      | Unix.EROFS -> 30
      | Unix.ESPIPE -> 29
      | Unix.ESRCH -> 3
      | Unix.EXDEV -> 18
      | Unix.EWOULDBLOCK -> 11
      | Unix.EINPROGRESS -> 115
      | Unix.EALREADY -> 114
      | Unix.ENOTSOCK -> 88
      | Unix.EDESTADDRREQ -> 89
      | Unix.EMSGSIZE -> 90
      | Unix.EPROTOTYPE -> 91
      | Unix.ENOPROTOOPT -> 92
      | Unix.EPROTONOSUPPORT -> 93
      | Unix.ESOCKTNOSUPPORT -> 94
      | Unix.EOPNOTSUPP -> 95
      | Unix.EPFNOSUPPORT -> 96
      | Unix.EAFNOSUPPORT -> 97
      | Unix.EADDRINUSE -> 98
      | Unix.EADDRNOTAVAIL -> 99
      | Unix.ENETDOWN -> 100
      | Unix.ENETUNREACH -> 101
      | Unix.ENETRESET -> 102
      | Unix.ECONNABORTED -> 103
      | Unix.ECONNRESET -> 104
      | Unix.ENOBUFS -> 105
      | Unix.EISCONN -> 106
      | Unix.ENOTCONN -> 107
      | Unix.ESHUTDOWN -> 108
      | Unix.ETOOMANYREFS -> 109
      | Unix.ETIMEDOUT -> 110
      | Unix.ECONNREFUSED -> 111
      | Unix.EHOSTDOWN -> 112
      | Unix.EHOSTUNREACH -> 113
      | Unix.ELOOP -> 40
      | Unix.EOVERFLOW -> 75
      | Unix.EUNKNOWNERR(i) -> i

  method put_errno err =
    put_reg R_EAX (Int64.of_int ~-(self#errno err))

  val mutable next_fresh_addr = 0x50000000L

  method fresh_addr size = 
    let ret = next_fresh_addr in
      next_fresh_addr <- Int64.add next_fresh_addr size;
      next_fresh_addr <- Int64.logand 0xffff_ffff_ffff_f000L
	(Int64.add next_fresh_addr 0x0fffL); (* page align *)
      ret

  val the_break = ref None

  method string_create len =
    try String.create len
    with Invalid_argument("String.create")
	-> raise (Unix.Unix_error(Unix.EFAULT, "String.create", ""))

  method do_write fd bytes count =
    (try
       (match fd with
	  | 1 -> Array.iter print_char bytes;
	      put_reg R_EAX (Int64.of_int count)
	  | _ ->
	      let str = Array.fold_left (^) ""
		(Array.map (String.make 1) bytes)
	      in
	      let (ufd, toapp) = if ((fd = 1) || (fd = 2))  then (Unix.stdout, (Printf.sprintf "[Trans-eval fd %d]: " fd)) else ((self#get_fd fd), "") in
	      let strout = toapp ^ str in
		match Unix.write (ufd) strout 0 (String.length strout)
		with
		  | i when i = count -> put_reg R_EAX (Int64.of_int count)
		  | i when i = (count + (String.length toapp)) ->  put_reg R_EAX (Int64.of_int count)
		  | _ -> raise (Unix.Unix_error(Unix.EINTR, "", "")))
     with
       | Unix.Unix_error(err, _, _) -> self#put_errno err);
    ()

  method do_unix_read fd addr count =
    let rec loop left a =
      if (left <= 0) then 0 else
	let chunk = if (left < 4096) then left else 4096 in
	let str = self#string_create chunk in
	let num_read = Unix.read fd str 0 chunk in
	  if num_read = 4096 && (Int64.logand a 0xfffL) = 0L then
	    fm#store_page_conc a str
	  else
	    fm#store_str a 0L (String.sub str 0 num_read);
	  num_read +
	    (loop (left - chunk) (Int64.add a (Int64.of_int chunk)))
    in
      loop count addr
	
  method read_sockaddr addr addrlen =
    let family = load_short addr and
	buf = Int64.add 2L addr and
	len = addrlen - 2 in
      match family with
	| 1 -> let path = fm#read_cstr buf in
	    if path = "" then
	      (* I don't think OCaml can handle the Linux
		 "abstract namespace" extension. But sometimes (e.g.,
		 as used by the X libraries) the abstract name is
		 the same as a pathname that will also work, so try that.
	      *)
	      let path' = fm#read_cstr (Int64.add buf 1L)
	      in
		Unix.ADDR_UNIX(path')
	    else
	      Unix.ADDR_UNIX(path)
	| 2 -> 
	    assert(len = 6);
	    let port_be = load_short buf and
		addr_h  = load_byte (lea buf 0 0 2) and
		addr_mh = load_byte (lea buf 0 0 3) and
		addr_ml = load_byte (lea buf 0 0 4) and
		addr_l  = load_byte (lea buf 0 0 5) in
	    let port = ((port_be land 0xff) lsl 8) lor (port_be lsr 8) and
		addr = (Unix.inet_addr_of_string
			  (Printf.sprintf "%d.%d.%d.%d" addr_h addr_mh
			     addr_ml addr_l))
	    in
	      Unix.ADDR_INET(addr, port)
	| _ -> failwith "Unexpected sockaddr family"

  method write_sockaddr sockaddr_oc addr addrlen_ptr =
    let dotted_addr_to_dat str =
      let dot1 = String.index str '.' in
      let dot2 = String.index_from str dot1 '.' in
      let dot3 = String.index_from str dot2 '.' in
      let b1 = int_of_string (String.sub str 0 dot1) and
	  b2 = int_of_string (String.sub str (dot1 + 1) (dot2 - dot1 - 1)) and
	  b3 = int_of_string (String.sub str (dot2 + 1) (dot3 - dot2 - 1)) and
	  b4 = int_of_string (String.sub str (dot3 + 1)
				((String.length str) - dot3 - 1))
      in
	Printf.sprintf "%c%c%c%c" (Char.chr b1) (Char.chr b2)
	  (Char.chr b3) (Char.chr b4)
    in
    let (family, data) = 
      match sockaddr_oc with
	| Unix.ADDR_UNIX(path) ->
	    ("\001\000", path)
	| Unix.ADDR_INET(addr, port) ->
	    let port_dat = Printf.sprintf "%c%c"
	      (Char.chr (port lsr 8)) (Char.chr (port land 0xff)) and
		addr_str = Unix.string_of_inet_addr addr in
	    let addr_dat = dotted_addr_to_dat addr_str in
	      ("\002\000", port_dat ^ addr_dat)
    in
    let sa_data = family ^ data in
    let real_len = String.length sa_data in
    let buf_len = Int64.to_int (load_word addrlen_ptr) in
    let write_len = min real_len buf_len in
      fm#store_str addr 0L (String.sub sa_data 0 write_len);
      store_word addrlen_ptr 0 (Int64.of_int real_len);

  method oc_kind_to_mode kind = match kind with
    | Unix.S_REG  -> 0o0100000
    | Unix.S_DIR  -> 0o0040000
    | Unix.S_CHR  -> 0o0020000
    | Unix.S_BLK  -> 0o0060000
    | Unix.S_LNK  -> 0o0120000
    | Unix.S_FIFO -> 0o0010000
    | Unix.S_SOCK -> 0o0140000

  method flags_to_oc_flags flags =
    (if (flags land 0x3) = 0        then [Unix.O_RDONLY]   else []) @
      (if (flags land 0x3)= 1       then [Unix.O_WRONLY]   else []) @
      (if (flags land 0x3) = 2      then [Unix.O_RDWR]     else []) @
      (if (flags land 0o4000) != 0  then [Unix.O_NONBLOCK] else []) @
      (if (flags land 0o2000) != 0  then [Unix.O_APPEND]   else []) @
      (if (flags land 0o100) != 0   then [Unix.O_CREAT]    else []) @
      (if (flags land 0o1000) != 0  then [Unix.O_TRUNC]    else []) @
      (if (flags land 0o200) != 0   then [Unix.O_EXCL]     else []) @
      (if (flags land 0o10000) != 0 then [Unix.O_SYNC]     else [])

  method write_oc_statbuf addr oc_buf =
    let dev = Int64.of_int oc_buf.Unix.st_dev and
	ino = Int64.of_int oc_buf.Unix.st_ino and
	mode = Int64.of_int (oc_buf.Unix.st_perm lor 
			       (self#oc_kind_to_mode oc_buf.Unix.st_kind)) and
	nlink = Int64.of_int oc_buf.Unix.st_nlink and
	uid = Int64.of_int oc_buf.Unix.st_uid and
	gid = Int64.of_int oc_buf.Unix.st_gid and
	rdev = Int64.of_int oc_buf.Unix.st_rdev and
	size = Int64.of_int oc_buf.Unix.st_size and
	atime = Int64.of_float oc_buf.Unix.st_atime and
	mtime = Int64.of_float oc_buf.Unix.st_mtime and
	ctime = Int64.of_float oc_buf.Unix.st_ctime and
	blksize = 4096L and
	blocks = Int64.of_int (oc_buf.Unix.st_size/4096)
    in
      store_word addr 0 dev;
      store_word addr 4 0L;       (* high bits of dev *)
      store_word addr 12 ino;     (* 32-bit inode *)
      store_word addr 16 mode;
      store_word addr 20 nlink;
      store_word addr 24 uid;
      store_word addr 28 gid;
      store_word addr 32 rdev;
      store_word addr 36 0L;      (* high bits of rdev *)
      store_word addr 44 size;
      store_word addr 48 0L;      (* high bits of size *)
      store_word addr 52 blksize;
      store_word addr 56 blocks;
      store_word addr 60 0L;      (* high bits of blocks *)
      store_word addr 64 atime;
      store_word addr 68 0L;      (* atime nanosecs *)
      store_word addr 72 mtime;
      store_word addr 76 0L;      (* mtime naonsecs *)
      store_word addr 80 ctime;
      store_word addr 84 0L;      (* ctime nanosecs *)
      store_word addr 89 ino;     (* low bits of 64-bit inode *)
      store_word addr 92 0L;      (* high bits of 64-bit inode *)

  method write_fake_statfs64buf addr =
    (* OCaml's Unix module doesn't provide an interface for this
       information, so we just make it up. *)
    let f_type   = 0x52654973L (* REISERFS_SUPER_MAGIC *) and
	f_bsize  = 4096L and
	f_blocks = 244182546L and
	f_bfree  = 173460244L and
	f_bavail = 173460244L and
	f_files  = 0L and
	f_ffree  = 0L and
	f_fsid_0 = 0L and
	f_fsid_1 = 0L and
	f_namelen = 255L and
	f_frsize = 4096L
    in
      store_word addr  0 f_type;
      store_word addr  4 f_bsize;
      store_word addr  8 f_blocks;
      store_word addr 12 0L;     (* high word of f_blocks *)
      store_word addr 16 f_bfree;
      store_word addr 20 0L;     (* high word of f_bfree *)
      store_word addr 24 f_bavail;
      store_word addr 28 0L;     (* high word of f_bavail *)
      store_word addr 32 f_files;
      store_word addr 36 0L;     (* high word of f_files *)
      store_word addr 40 f_ffree;
      store_word addr 44 0L;     (* high word of f_ffree *)
      store_word addr 48 f_fsid_0;
      store_word addr 52 f_fsid_1;
      store_word addr 56 f_namelen;
      store_word addr 60 f_frsize
      (* offsets 64, 68, 72, 76, 80: f_spare[5] reserved *)

  (* This works for either a struct timeval or a struct timespec,
     depending on the resolution *)
  method write_ftime_as_words ftime addr resolution =
    let fsecs = floor ftime in
    let secs = Int64.of_float fsecs and
	fraction = Int64.of_float (resolution *. (ftime -. fsecs)) in
      store_word addr 0 secs;
      store_word addr 4 fraction

  val mutable proc_identities = None

  method set_proc_identities id =
    proc_identities <- id

  method get_pid =
    match proc_identities with
      | Some (pid, _, _, _) -> pid
      | None -> Unix.getpid ()

  method get_ppid =
    match proc_identities with
      | Some (_, ppid, _, _) -> ppid
      | None -> Unix.getppid ()

  method get_pgrp =
    match proc_identities with
      | Some (_, _, pgrp, _) -> pgrp
      | None -> failwith "OCaml has no getpgrp()"

  method get_sid =
    match proc_identities with
      | Some (_, _, _, sid) -> sid
      | None -> failwith "OCaml has no getsid()"

  method sys_access path mode =
    let oc_mode =
      (if   (mode land 0x7)= 0 then [Unix.F_OK] else []) @
	(if (mode land 0x1)!=0 then [Unix.X_OK] else []) @
	(if (mode land 0x2)!=0 then [Unix.W_OK] else []) @
	(if (mode land 0x4)!=0 then [Unix.R_OK] else []) 
    in
      try
	Unix.access path oc_mode;
	put_reg R_EAX 0L
      with
	| Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_brk addr =
    let cur_break = match !the_break with
      | Some b -> b
      | None ->
	  (let first_break = 
	     (match !linux_initial_break with
		| Some b -> b
		| None -> 0x08200000L (* vague guess *) )
	   in
	     the_break := Some first_break;
	     first_break)
    in
    let new_break = 
      if addr < cur_break then
	cur_break
      else 
	(fm#zero_fill cur_break (Int64.to_int (Int64.sub addr cur_break));
	 addr)
    in
      the_break := Some new_break;
      put_reg R_EAX new_break;

  method sys_clock_gettime clkid timep =
    match clkid with
      | 1 -> (* CLOCK_MONOTONIC *)
	  (* For Linux, this is pretty much time since boot, unless you're
	     changing the system's clock while running the program.
	     Pretend we were booted on 2010-03-18. *)
	  (self#write_ftime_as_words (Unix.gettimeofday () -. 1268959142.0)
	     timep 1000000000.0);
	  put_reg R_EAX 0L
      | 0 -> (* CLOCK_REALTIME *)
	  self#write_ftime_as_words (Unix.gettimeofday ()) timep 1000000000.0;
	  put_reg R_EAX 0L
      | _ -> self#put_errno Unix.EINVAL (* unsupported clock type *)

  method sys_close fd =
    try
      if (fd <> 1 && fd <> 2) then
	Unix.close (self#get_fd fd);
      Array.set unix_fds fd None;
      put_reg R_EAX 0L (* success *)
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_connect sockfd addr addrlen =
    try
      Unix.connect (self#get_fd sockfd) (self#read_sockaddr addr addrlen)
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_exit_group status =
    raise (SimulatedExit(status))

  method sys_futex uaddr op value timebuf uaddr2 val3 =
    let ret = 
      match (op, value) with
	| (129 (* FUTEX_WAKE_PRIVATE *), _) ->
	    0L (* never anyone to wake *)
	| (393 (* FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME *), _) ->
	    (Int64.of_int ~-(self#errno Unix.EAGAIN))
	      (* simulate lack of setup? *)
    | _ -> raise( UnhandledSysCall("Unhandled futex operation"));
    in
      put_reg R_EAX ret

  method sys_ugetrlimit rsrc buf =
    store_word buf 0 0xffffffffL; (* infinity *)
    store_word buf 4 0xffffffffL; (* infinity *)
    put_reg R_EAX 0L (* success *)

  method sys_getgid32 () = 
    put_reg R_EAX (Int64.of_int (Unix.getgid ()))

  method sys_getegid32 () = 
    put_reg R_EAX (Int64.of_int (Unix.getegid ()))

  method sys_getuid32 () = 
    put_reg R_EAX (Int64.of_int (Unix.getuid ()))

  method sys_geteuid32 () = 
    put_reg R_EAX (Int64.of_int (Unix.geteuid ()))

  method sys_getpid () =
    let pid = self#get_pid in
      put_reg R_EAX (Int64.of_int pid)

  method sys_getpgid target =
    assert(target = 0 || target = self#get_pid); (* Only works on ourselves *)
    let pgid = self#get_pgrp in
      put_reg R_EAX (Int64.of_int pgid)

  method sys_getpgrp () =
    let pgid = self#get_pgrp in
      put_reg R_EAX (Int64.of_int pgid)

  method sys_getppid () =
    let ppid = self#get_ppid in
      put_reg R_EAX (Int64.of_int ppid)

  method sys_getsid () =
    let sid = self#get_sid in
      put_reg R_EAX (Int64.of_int sid)

  method sys_gettid =
    (* On Linux, thread id is the process id *)
    let tid = Int64.of_int (self#get_pid) in
      put_reg R_EAX tid
    
  method sys_getpeername sockfd addr addrlen_ptr =
    try
      let socka_oc = Unix.getpeername (self#get_fd sockfd) in
	self#write_sockaddr socka_oc addr addrlen_ptr;
	put_reg R_EAX 0L (* success *)
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_getsockname sockfd addr addrlen_ptr =
    try
      let socka_oc = Unix.getsockname (self#get_fd sockfd) in
	self#write_sockaddr socka_oc addr addrlen_ptr;
	put_reg R_EAX 0L (* success *)
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_gettimeofday timep zonep =
    if timep <> 0L then
      self#write_ftime_as_words (Unix.gettimeofday ()) timep 1000000.0;
    if zonep <> 0L then
      (* Simulate a modern system where the kernel knows nothing about
	 the timezone: *)
      (store_word zonep 0 0L; (* UTC *)
       store_word zonep 4 0L); (* no DST *)
    put_reg R_EAX 0L

  method sys_ioctl fd req argp =
    match req with
      | 0x5401L -> (* put_reg R_EAX 0L *)
	  (*	  let attrs = Unix.tcgetattr (self#get_fd fd) in *)
	  raise (UnhandledSysCall ("Unhandled TCGETS ioctl"))
      | _ -> 	  raise (UnhandledSysCall ("Unhandled ioct syscall"))


  method sys_lseek (fd: int) (offset: Int64.t) (whence: int) =
    try
      let seek_cmd = match whence with
	| 0 -> Unix.SEEK_SET
	| 1 -> Unix.SEEK_CUR
	| 2 -> Unix.SEEK_END
	| _ -> raise
	    (Unix.Unix_error(Unix.EINVAL, "Bad whence argument to llseek", ""))
      in
      let loc = Unix.lseek (self#get_fd fd) (Int64.to_int offset) seek_cmd in
	put_reg R_EAX (Int64.of_int loc);
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys__llseek fd offset resultp whence =
    try
      let seek_cmd = match whence with
	| 0 -> Unix.SEEK_SET
	| 1 -> Unix.SEEK_CUR
	| 2 -> Unix.SEEK_END
	| _ -> raise
	    (Unix.Unix_error(Unix.EINVAL, "Bad whence argument to llseek", ""))
      in
      let loc = Unix.lseek (self#get_fd fd) (Int64.to_int offset) seek_cmd in
	fm#store_long_conc resultp (Int64.of_int loc);
	put_reg R_EAX 0L
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_mkdir path mode =
    try
      Unix.mkdir path mode;
      put_reg R_EAX 0L
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err
	  
  method sys_mmap2 addr length prot flags fd pgoffset =
    let do_read addr = 
      let len = Int64.to_int length in
      let old_loc = Unix.lseek (self#get_fd fd) 0 Unix.SEEK_CUR in
      let _ = Unix.lseek (self#get_fd fd) (4096*pgoffset) Unix.SEEK_SET in
      let _ = self#do_unix_read (self#get_fd fd) addr len in
      let _ = Unix.lseek (self#get_fd fd) old_loc Unix.SEEK_SET in
	(* assert(nr = len); *)
	addr
    in
    let ret =
      match (addr, length, prot, flags, fd, pgoffset) with
	| (0L, _, 0x3L (* PROT_READ|PROT_WRITE *),
	   0x22L (* MAP_PRIVATE|MAP_ANONYMOUS *), -1, _) ->
	    let fresh = self#fresh_addr length in
	      zero_region fresh (Int64.to_int length);
	      fresh
	| (_, _, (0x3L|0x7L) (* PROT_READ|PROT_WRITE|PROT_EXEC) *),
	   0x32L (* MAP_PRIVATE|FIXED|ANONYMOUS *), -1, _) ->
	    zero_region addr (Int64.to_int length);
	    addr
	| (0L, _, 
	   (0x1L|0x5L) (* PROT_READ|PROT_EXEC *),
	   (0x802L|0x2L|0x1L) (* MAP_PRIVATE|MAP_DENYWRITE|MAP_SHARED *), _, _) ->
	    let dest_addr = self#fresh_addr length in
	      do_read dest_addr
	| (_, _, (0x3L|0x7L) (* PROT_READ|PROT_WRITE|PROT_EXEC *),
	   0x812L (* MAP_DENYWRITE|PRIVATE|FIXED *), _, _) ->
	    do_read addr
	| _ -> failwith "Unhandled mmap operation"
    in
      put_reg R_EAX ret

  method sys_mprotect addr len prot =
    (* treat as no-op *)
    put_reg R_EAX 0L;

  method sys_munmap addr len =
    (* treat as no-op *)
    put_reg R_EAX 0L

  method sys_open path flags mode =
    try
      let oc_flags = self#flags_to_oc_flags flags in
      let oc_fd = Unix.openfile path oc_flags mode and
	  vt_fd = self#fresh_fd () in
	Array.set unix_fds vt_fd (Some oc_fd);
	put_reg R_EAX (Int64.of_int vt_fd)
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_read fd buf count =
    try
      let str = self#string_create count in
      let num_read = Unix.read (self#get_fd fd) str 0 count in
	fm#store_str buf 0L (String.sub str 0 num_read);
	put_reg R_EAX (Int64.of_int num_read)
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err
	  
  method sys_readlink path out_buf buflen =
    let real = Unix.readlink path in
    let written = min buflen (String.length real) in
      fm#store_str out_buf 0L (String.sub real 0 written);
      put_reg R_EAX (Int64.of_int written);

  method sys_select nfds readfds writefds exceptfds timeout =
    put_reg R_EAX 0L (* no events *)
    
  method sys_setgid32 gid =
    Unix.setgid gid;
    put_reg R_EAX 0L (* success *)

  method sys_setuid32 uid =
    Unix.setuid uid;
    put_reg R_EAX 0L (* success *)

  method sys_set_robust_list addr len =
    put_reg R_EAX 0L (* success *)

  method sys_set_thread_area uinfo =
    let old_ent = Int64.to_int (load_word (lea uinfo 0 0 0))
    and
	base  = load_word (lea uinfo 0 0 4) and
	limit = load_word (lea uinfo 0 0 8) in
      if !opt_trace_syscalls then
	Printf.printf " set_thread_area({entry: %d, base: %Lx, limit: %Ld})\n"
	  old_ent base limit;
      (match (old_ent, base, limit) with
	 | (-1, _, _) ->
	     let new_ent = 12 in
	       linux_setup_tcb_seg fm new_ent 0x60000000L base limit;
	       store_word uinfo 0 (Int64.of_int new_ent);
	       put_reg R_EAX 0L (* success *)
	 | _ -> failwith "Unhandled args to set_thread_area")

  method sys_set_tid_address addr =
    let pid = self#get_pid in
      put_reg R_EAX (Int64.of_int pid)

  method sys_rt_sigaction signum newbuf oldbuf setlen =
    (if oldbuf = 0L then () else
      let (action, mask_low, mask_high, flags) =
	match signum with
          | 11 | 4 | 13
	  | 8 (* SIGFPE *) -> (0L, 0L, 0L, 0L)
	  | _ -> raise (UnhandledSysCall("Unhandled old signal in rt_sigaction"));
      in
	store_word oldbuf 0 action;
	store_word oldbuf 4 flags;
	store_word oldbuf 8 0L; (* restorer *)
	store_word oldbuf 12 mask_low;
	store_word oldbuf 12 mask_high);
    put_reg R_EAX 0L; (* success *)

  method sys_rt_sigprocmask how newset oldset setlen =
    (if oldset = 0L then () else
       failwith "Can't report old mask");
    put_reg R_EAX 0L (* success *)

  method sys_socket dom_i typ_i prot_i =
    try
      let domain = match dom_i with
	| 1 -> Unix.PF_UNIX
	| 2 -> Unix.PF_INET
	| 10 -> Unix.PF_INET6
	| _ -> raise (Unix.Unix_error(Unix.EINVAL, "Bad protocol family", ""))
      in
      let typ = match typ_i land 0o777 with
	| 1 -> Unix.SOCK_STREAM
	| 2 -> Unix.SOCK_DGRAM
	| 3 -> Unix.SOCK_RAW
	| 5 -> Unix.SOCK_SEQPACKET
	| _ -> raise (Unix.Unix_error(Unix.EINVAL, "Bad socket type", ""))
      in
      let oc_fd = Unix.socket domain typ prot_i and
	  vt_fd = self#fresh_fd () in
	Array.set unix_fds vt_fd (Some oc_fd);
	put_reg R_EAX (Int64.of_int vt_fd)
    with 
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_stat64 path buf_addr =
    try
      let oc_buf = Unix.stat path in
	self#write_oc_statbuf buf_addr oc_buf;
	put_reg R_EAX 0L (* success *)
    with
      | Unix.Unix_error(err, _, _) -> self#put_errno err

  method sys_fstat64 fd buf_addr =
    let oc_buf =
      (if (fd <> 1) then
	 Unix.fstat (self#get_fd fd)
       else
	 Unix.stat "/etc/group") (* pretend stdout is always redirected *) in
      self#write_oc_statbuf buf_addr oc_buf;
      put_reg R_EAX 0L (* success *)

  method sys_statfs64 path buf_len struct_buf =
    assert(buf_len = 84);
    self#write_fake_statfs64buf struct_buf;
    put_reg R_EAX 0L (* success *)

  method sys_time addr =
    let time = Int64.of_float (Unix.time ()) in
      if addr != 0L then
	store_word addr 0 time else ();
      put_reg R_EAX time

  method sys_times addr =
    let float_to_clocks f = Int64.of_float (f *. 100.0) in
    let pt = Unix.times () in
    let ut = float_to_clocks (pt.Unix.tms_utime) and
	st = float_to_clocks (pt.Unix.tms_stime) and
	cut = float_to_clocks (pt.Unix.tms_cutime) and
	cst = float_to_clocks (pt.Unix.tms_cstime) in
      (* Printf.printf "times: %Ld %Ld %Ld %Ld\n" ut st cut cst; *)
      store_word addr 0 ut;
      store_word addr 4 st;		 
      store_word addr 8 cut;
      store_word addr 12 cst;
      put_reg R_EAX (Int64.add ut st)

  method sys_uname buf =
    List.iter2
      (fun i str ->
	 fm#store_cstr buf (Int64.mul 65L i) str)
      [0L; 1L; 2L; 3L; 4L; 5L]
      ["Linux"; (* sysname *)
       "amuro"; (* nodename *)
       "2.6.26-2-amd64"; (* release *)
       "#1 SMP Fri Mar 27 04:02:59 UTC 2009"; (*version*)
       "i686"; (* machine *)
       "example.com" (* domain *)
      ];
    put_reg R_EAX 0L (* success *)

  method sys_write fd bytes count =
    self#do_write fd bytes count

  method sys_writev fd iov cnt =
    let bytes =
      Array.concat
	(Vine_util.mapn
	   (fun i -> fm#read_buf
	      (load_word (lea iov i 8 0)) (* iov_base *)
	      (Int64.to_int (load_word (lea iov i 8 4))))
	   (* iov_len *)
	   (cnt - 1)) in
      self#do_write fd bytes (Array.length bytes)

  method handle_linux_syscall () =
    let get_reg r = fm#get_word_var_concretize r
      !opt_measure_influence_syscall_args "syscall arg" in
    (let syscall_num = Int64.to_int (get_reg R_EAX) and
	 read_1_reg () = get_reg R_EBX in
     let read_2_regs () =
       let ebx = read_1_reg () and
	   ecx = get_reg R_ECX in
	 (ebx, ecx) in
     let read_3_regs () = 
       let (ebx, ecx) = read_2_regs () and
	   edx = get_reg R_EDX in
	 (ebx, ecx, edx) in
     let read_4_regs () =
       let (ebx, ecx, edx) = read_3_regs () and
	   esi = get_reg R_ESI in
	 (ebx, ecx, edx, esi) in
     let read_5_regs () =
       let (ebx, ecx, edx, esi) = read_4_regs () and
	   edi = get_reg R_EDI in
	 (ebx, ecx, edx, esi, edi) in
     let read_6_regs () =
       let (ebx, ecx, edx, esi, edi) = read_5_regs () and
	   ebp = get_reg R_EBP in
	 (ebx, ecx, edx, esi, edi, ebp)
     in
       match syscall_num with 
	 | 0 -> (* restart_syscall *)
	     raise (UnhandledSysCall( "Unhandled Linux system call restart_syscall (0)"))
	 | 1 -> (* exit *)
	     raise (UnhandledSysCall( "Unhandled Linux system call exit (1)"))
	 | 2 -> (* fork *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fork (2)"))
	 | 3 -> (* read *)		    
	     let (ebx, ecx, edx) = read_3_regs () in
	     let fd    = Int64.to_int ebx and
		 buf   = ecx and
		 count = Int64.to_int edx in
	       if !opt_trace_syscalls then
		 Printf.printf "read(%d, 0x%08Lx, %d)" fd buf count;
	       self#sys_read fd buf count;
	 | 4 -> (* write *)
	     let (ebx, ecx, edx) = read_3_regs () in
	     let fd    = Int64.to_int ebx and
		 buf   = ecx and
		 count = Int64.to_int edx in
	       if !opt_trace_syscalls then
		 Printf.printf "write(%d, 0x%08Lx, %d)\n" fd buf count;
	       let bytes = fm#read_buf buf count in
		 self#sys_write fd bytes count
	 | 5 -> (* open *)
	     let (ebx, ecx) = read_2_regs () in
	     let edx = (if (Int64.logand ecx 0o100L) <> 0L then
			  get_reg R_EDX
			else
			  0L) in
	     let path_buf = ebx and
		 flags    = Int64.to_int ecx and
		 mode     = Int64.to_int edx in
	     let path = fm#read_cstr path_buf in
	       if !opt_trace_syscalls then
		 Printf.printf "open(\"%s\", 0x%x, 0o%o)" path flags mode;
	       self#sys_open path flags mode
	 | 6 -> (* close *)
	     let ebx = read_1_reg () in
	     let fd = Int64.to_int ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "close(%d)" fd;
	       self#sys_close fd
	 | 7 -> (* waitpid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call waitpid (7)"))
	 | 8 -> (* creat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call creat (8)"))
	 | 9 -> (* link *)
	     raise (UnhandledSysCall( "Unhandled Linux system call link (9)"))
	 | 10 -> (* unlink *)
	     raise (UnhandledSysCall( "Unhandled Linux system call unlink (10)"))
	 | 11 -> (* execve *)
	     raise (UnhandledSysCall( "Unhandled Linux system call execve (11)"))
	 | 12 -> (* chdir *)
	     raise (UnhandledSysCall( "Unhandled Linux system call chdir (12)"))
	 | 13 -> (* time *)
	     let ebx = read_1_reg () in
	     let addr = ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "time(0x%08Lx)" addr;
	       self#sys_time addr
	 | 14 -> (* mknod *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mknod (14)"))
	 | 15 -> (* chmod *)
	     raise (UnhandledSysCall( "Unhandled Linux system call chmod (15)"))
	 | 16 -> (* lchown *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lchown (16)"))
	 | 17 -> (* break *)
	     raise (UnhandledSysCall( "Unhandled Linux system call break (17)"))
	 | 18 -> (* oldstat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call oldstat (18)"))
	 | 19 -> (* lseek *)
	     let (ebx, ecx, edx) = read_3_regs () in
	     let (fd: int) = Int64.to_int ebx and
		 offset = ecx and
		 whence = (Int64.to_int edx) in
	       if !opt_trace_syscalls then
		 Printf.printf "lseek(%d, %Ld, %d)" fd offset whence;
	       self#sys_lseek fd offset whence
	 | 20 -> (* getpid *)
	     if !opt_trace_syscalls then
	       Printf.printf "getpid()";
	     self#sys_getpid ()
	 | 21 -> (* mount *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mount (21)"))
	 | 22 -> (* umount *)
	     raise (UnhandledSysCall( "Unhandled Linux system call umount (22)"))
	 | 23 -> (* setuid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setuid (23)"))
	 | 24 -> (* getuid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getuid (24)"))
	 | 25 -> (* stime *)
	     raise (UnhandledSysCall( "Unhandled Linux system call stime (25)"))
	 | 26 -> (* ptrace *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ptrace (26)"))
	 | 27 -> (* alarm *)
	     raise (UnhandledSysCall( "Unhandled Linux system call alarm (27)"))
	 | 28 -> (* oldfstat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call oldfstat (28)"))
	 | 29 -> (* pause *)
	     raise (UnhandledSysCall( "Unhandled Linux system call pause (29)"))
	 | 30 -> (* utime *)
	     raise (UnhandledSysCall( "Unhandled Linux system call utime (30)"))
	 | 31 -> (* stty *)
	     raise (UnhandledSysCall( "Unhandled Linux system call stty (31)"))
	 | 32 -> (* gtty *)
	     raise (UnhandledSysCall( "Unhandled Linux system call gtty (32)"))
	 | 33 -> (* access *)
	     let (ebx, ecx) = read_2_regs () in
	     let path_buf = ebx and
		 mode     = Int64.to_int ecx in
	     let path = fm#read_cstr path_buf in
	       if !opt_trace_syscalls then
		 Printf.printf "access(\"%s\", 0x%x)" path mode;
	       self#sys_access path mode
	 | 34 -> (* nice *)
	     raise (UnhandledSysCall( "Unhandled Linux system call nice (34)"))
	 | 35 -> (* ftime *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ftime (35)"))
	 | 36 -> (* sync *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sync (36)"))
	 | 37 -> (* kill *)
	     raise (UnhandledSysCall( "Unhandled Linux system call kill (37)"))
	 | 38 -> (* rename *)
	     raise (UnhandledSysCall( "Unhandled Linux system call rename (38)"))
	 | 39 -> (* mkdir *)
	     let (ebx, ecx) = read_2_regs () in
	     let path_buf = ebx and
		 mode     = Int64.to_int ecx in
	     let path = fm#read_cstr path_buf in
	       if !opt_trace_syscalls then
		 Printf.printf "mkdir(\"%s\", 0x%x)" path mode;
	       self#sys_mkdir path mode
	 | 40 -> (* rmdir *)
	     raise (UnhandledSysCall( "Unhandled Linux system call rmdir (40)"))
	 | 41 -> (* dup *)
	     raise (UnhandledSysCall( "Unhandled Linux system call dup (41)"))
	 | 42 -> (* pipe *)
	     raise (UnhandledSysCall( "Unhandled Linux system call pipe (42)"))
	 | 43 -> (* times *)
	     let ebx = read_1_reg () in
	     let addr = ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "times(0x%08Lx)" addr;
	       self#sys_times addr
	 | 44 -> (* prof *)
	     raise (UnhandledSysCall( "Unhandled Linux system call prof (44)"))
	 | 45 -> (* brk *)
	     let ebx = read_1_reg () in
	     let addr = ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "brk(0x%08Lx)" addr;
	       self#sys_brk addr
	 | 46 -> (* setgid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setgid (46)"))
	 | 47 -> (* getgid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getgid (47)"))
	 | 48 -> (* signal *)
	     raise (UnhandledSysCall( "Unhandled Linux system call signal (48)"))
	 | 49 -> (* geteuid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call geteuid (49)"))
	 | 50 -> (* getegid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getegid (50)"))
	 | 51 -> (* acct *)
	     raise (UnhandledSysCall( "Unhandled Linux system call acct (51)"))
	 | 52 -> (* umount2 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call umount2 (52)"))
	 | 53 -> (* lock *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lock (53)"))
	 | 54 -> (* ioctl *)
	     let (ebx, ecx, edx) = read_3_regs () in
	     let fd   = Int64.to_int ebx and
		 req  = ecx and
		 argp = edx in
	       if !opt_trace_syscalls then
		 Printf.printf "ioctl(%d, 0x%Lx, 0x%08Lx)" fd req argp;
	       self#sys_ioctl fd req argp;
	 | 55 -> (* fcntl *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fcntl (55)"))
	 | 56 -> (* mpx *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mpx (56)"))
	 | 57 -> (* setpgid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setpgid (57)"))
	 | 58 -> (* ulimit *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ulimit (58)"))
	 | 59 -> (* oldolduname *)
	     raise (UnhandledSysCall( "Unhandled Linux system call oldolduname (59)"))
	 | 60 -> (* umask *)
	     raise (UnhandledSysCall( "Unhandled Linux system call umask (60)"))
	 | 61 -> (* chroot *)
	     raise (UnhandledSysCall( "Unhandled Linux system call chroot (61)"))
	 | 62 -> (* ustat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ustat (62)"))
	 | 63 -> (* dup2 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call dup2 (63)"))
	 | 64 -> (* getppid *)
	     if !opt_trace_syscalls then
	       Printf.printf "getppid()";
	     self#sys_getppid ()
	 | 65 -> (* getpgrp *)
	     if !opt_trace_syscalls then
	       Printf.printf "getpgrp()";
	     self#sys_getpgrp ()
	 | 66 -> (* setsid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setsid (66)"))
	 | 67 -> (* sigaction *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sigaction (67)"))
	 | 68 -> (* sgetmask *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sgetmask (68)"))
	 | 69 -> (* ssetmask *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ssetmask (69)"))
	 | 70 -> (* setreuid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setreuid (70)"))
	 | 71 -> (* setregid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setregid (71)"))
	 | 72 -> (* sigsuspend *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sigsuspend (72)"))
	 | 73 -> (* sigpending *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sigpending (73)"))
	 | 74 -> (* sethostname *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sethostname (74)"))
	 | 75 -> (* setrlimit *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setrlimit (75)"))
	 | 76 -> (* getrlimit *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getrlimit (76)"))
	 | 77 -> (* getrusage *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getrusage (77)"))
	 | 78 -> (* gettimeofday *)
	     let (ebx, ecx) = read_2_regs () in
	     let timep = ebx and
		 zonep = ecx in
	       if !opt_trace_syscalls then
		 Printf.printf "gettimeofday(0x08%Lx, 0x08%Lx)" timep zonep;
	       self#sys_gettimeofday timep zonep
	 | 79 -> (* settimeofday *)
	     raise (UnhandledSysCall( "Unhandled Linux system call settimeofday (79)"))
	 | 80 -> (* getgroups *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getgroups (80)"))
	 | 81 -> (* setgroups *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setgroups (81)"))
	 | 82 -> (* select *)
	     raise (UnhandledSysCall( "Unhandled Linux system call select (82)"))
	 | 83 -> (* symlink *)
	     raise (UnhandledSysCall( "Unhandled Linux system call symlink (83)"))
	 | 84 -> (* oldlstat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call oldlstat (84)"))
	 | 85 -> (* readlink *)
	     let (ebx, ecx, edx) = read_3_regs () in
	     let path_buf = ebx and
		 out_buf  = ecx and
		 buflen   = Int64.to_int edx in
	     let path = fm#read_cstr path_buf in
	       if !opt_trace_syscalls then
		 Printf.printf "readlink(\"%s\", 0x%08Lx, %d)"
		   path out_buf buflen;
	       self#sys_readlink path out_buf buflen
	 | 86 -> (* uselib *)
	     raise (UnhandledSysCall( "Unhandled Linux system call uselib (86)"))
	 | 87 -> (* swapon *)
	     raise (UnhandledSysCall( "Unhandled Linux system call swapon (87)"))
	 | 88 -> (* reboot *)
	     raise (UnhandledSysCall( "Unhandled Linux system call reboot (88)"))
	 | 89 -> (* readdir *)
	     raise (UnhandledSysCall( "Unhandled Linux system call readdir (89)"))
	 | 90 -> (* mmap *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mmap (90)"))
	 | 91 -> (* munmap *)
	     let (ebx, ecx) = read_2_regs () in
	     let addr = ebx and
		 len  = ecx in
	       if !opt_trace_syscalls then
		 Printf.printf "munmap(0x%08Lx, %Ld)" addr len;
	       self#sys_munmap addr len
	 | 92 -> (* truncate *)
	     raise (UnhandledSysCall( "Unhandled Linux system call truncate (92)"))
	 | 93 -> (* ftruncate *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ftruncate (93)"))
	 | 94 -> (* fchmod *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fchmod (94)"))
	 | 95 -> (* fchown *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fchown (95)"))
	 | 96 -> (* getpriority *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getpriority (96)"))
	 | 97 -> (* setpriority *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setpriority (97)"))
	 | 98 -> (* profil *)
	     raise (UnhandledSysCall( "Unhandled Linux system call profil (98)"))
	 | 99 -> (* statfs *)
	     raise (UnhandledSysCall( "Unhandled Linux system call statfs (99)"))
	 | 100 -> (* fstatfs *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fstatfs (100)"))
	 | 101 -> (* ioperm *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ioperm (101)"))
	 | 102 -> (* socketcall *)
	     let (ebx, ecx) = read_2_regs () in
	     let call = Int64.to_int ebx and
		 args = ecx in
	       (match call with
		  | 1 -> 
		      let dom_i = Int64.to_int (load_word args) and
			  typ_i = Int64.to_int (load_word (lea args 0 0 4)) and
			  prot_i = Int64.to_int (load_word (lea args 0 0 8)) in
			Printf.printf "socket(%d, %d, %d)" dom_i typ_i prot_i;
			self#sys_socket dom_i typ_i prot_i
		  | 2 -> raise (UnhandledSysCall("Unhandled Linux system call bind (102:2)"))
		  | 3 -> 
		      let sockfd = Int64.to_int (load_word args) and
			  addr = load_word (lea args 0 0 4) and
			  addrlen = Int64.to_int (load_word (lea args 0 0 8))
		      in
			Printf.printf "connect(%d, 0x%08Lx, %d)"
			  sockfd addr addrlen;
			self#sys_connect sockfd addr addrlen
		  | 4 -> raise (UnhandledSysCall("Unhandled Linux system call listen (102:4)"))
		  | 5 -> raise (UnhandledSysCall("Unhandled Linux system call accept (102:5)"))
		  | 6 ->
		      let sockfd = Int64.to_int (load_word args) and
			  addr = load_word (lea args 0 0 4) and
			  addrlen_ptr = load_word (lea args 0 0 8)
		      in
			Printf.printf "getsockname(%d, 0x%08Lx, 0x%08Lx)"
			  sockfd addr addrlen_ptr;
			self#sys_getsockname sockfd addr addrlen_ptr
		  | 7 -> 
		      let sockfd = Int64.to_int (load_word args) and
			  addr = load_word (lea args 0 0 4) and
			  addrlen_ptr = load_word (lea args 0 0 8)
		      in
			Printf.printf "getpeername(%d, 0x%08Lx, 0x%08Lx)"
			  sockfd addr addrlen_ptr;
			self#sys_getpeername sockfd addr addrlen_ptr
		  | 8 -> raise (UnhandledSysCall("Unhandled Linux system call socketpair (102:8)"))
		  | 9 -> raise (UnhandledSysCall("Unhandled Linux system call send (102:9)"))
		  | 10 -> raise (UnhandledSysCall("Unhandled Linux system call recv (102:10)"))
		  | 11 -> raise (UnhandledSysCall("Unhandled Linux system call sendto (102:11)"))
		  | 12 -> raise (UnhandledSysCall("Unhandled Linux system call recvfrom (102:12)"))
		  | 13 -> raise (UnhandledSysCall("Unhandled Linux system call shutdown (102:13)"))
		  | 14 -> raise (UnhandledSysCall("Unhandled Linux system call setsockopt (102:14)"))
		  | 15 -> raise (UnhandledSysCall("Unhandled Linux system call getsockopt (102:15)"))
		  | 16 -> raise (UnhandledSysCall("Unhandled Linux system call sendmsg (102:16)"))
		  | 17 -> raise (UnhandledSysCall("Unhandled Linux system call recvmsg (102:17)"))
		  | 18 -> raise (UnhandledSysCall("Unhandled Linux system call accept4 (102:18)"))
		  | _ -> self#put_errno Unix.EINVAL)
	 | 103 -> (* syslog *)
	     raise (UnhandledSysCall( "Unhandled Linux system call syslog (103)"))
	 | 104 -> (* setitimer *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setitimer (104)"))
	 | 105 -> (* getitimer *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getitimer (105)"))
	 | 106 -> (* stat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call stat (106)"))
	 | 107 -> (* lstat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lstat (107)"))
	 | 108 -> (* fstat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fstat (108)"))
	 | 109 -> (* olduname *)
	     raise (UnhandledSysCall( "Unhandled Linux system call olduname (109)"))
	 | 110 -> (* iopl *)
	     raise (UnhandledSysCall( "Unhandled Linux system call iopl (110)"))
	 | 111 -> (* vhangup *)
	     raise (UnhandledSysCall( "Unhandled Linux system call vhangup (111)"))
	 | 112 -> (* idle *)
	     raise (UnhandledSysCall( "Unhandled Linux system call idle (112)"))
	 | 113 -> (* vm86old *)
	     raise (UnhandledSysCall( "Unhandled Linux system call vm86old (113)"))
	 | 114 -> (* wait4 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call wait4 (114)"))
	 | 115 -> (* swapoff *)
	     raise (UnhandledSysCall( "Unhandled Linux system call swapoff (115)"))
	 | 116 -> (* sysinfo *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sysinfo (116)"))
	 | 117 -> (* ipc *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ipc (117)"))
	 | 118 -> (* fsync *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fsync (118)"))
	 | 119 -> (* sigreturn *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sigreturn (119)"))
	 | 120 -> (* clone *)
	     raise (UnhandledSysCall( "Unhandled Linux system call clone (120)"))
	 | 121 -> (* setdomainname *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setdomainname (121)"))
	 | 122 -> (* uname *)
	     let ebx = read_1_reg () in
	     let buf = ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "uname(0x%08Lx)" buf;
	       self#sys_uname buf
	 | 123 -> (* modify_ldt *)
	     raise (UnhandledSysCall( "Unhandled Linux system call modify_ldt (123)"))
	 | 124 -> (* adjtimex *)
	     raise (UnhandledSysCall( "Unhandled Linux system call adjtimex (124)"))
	 | 125 -> (* mprotect *)
	     let (ebx, ecx, edx) = read_3_regs () in
	     let addr = ebx and
		 len  = ecx and
		 prot = edx in
	       if !opt_trace_syscalls then
		 Printf.printf "mprotect(0x%08Lx, %Ld, %Ld)" addr len prot;
	       self#sys_mprotect addr len prot
	 | 126 -> (* sigprocmask *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sigprocmask (126)"))
	 | 127 -> (* create_module *)
	     raise (UnhandledSysCall( "Unhandled Linux system call create_module (127)"))
	 | 128 -> (* init_module *)
	     raise (UnhandledSysCall( "Unhandled Linux system call init_module (128)"))
	 | 129 -> (* delete_module *)
	     raise (UnhandledSysCall( "Unhandled Linux system call delete_module (129)"))
	 | 130 -> (* get_kernel_syms *)
	     raise (UnhandledSysCall( "Unhandled Linux system call get_kernel_syms (130)"))
	 | 131 -> (* quotactl *)
	     raise (UnhandledSysCall( "Unhandled Linux system call quotactl (131)"))
	 | 132 -> (* getpgid *)
	     let eax = read_1_reg () in
	     let pid = Int64.to_int eax in
	       if !opt_trace_syscalls then
		 Printf.printf "getpgid()";
	       self#sys_getpgid pid
	 | 133 -> (* fchdir *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fchdir (133)"))
	 | 134 -> (* bdflush *)
	     raise (UnhandledSysCall( "Unhandled Linux system call bdflush (134)"))
	 | 135 -> (* sysfs *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sysfs (135)"))
	 | 136 -> (* personality *)
	     raise (UnhandledSysCall( "Unhandled Linux system call personality (136)"))
	 | 137 -> (* afs_syscall *)
	     raise (UnhandledSysCall( "Unhandled Linux system call afs_syscall (137)"))
	 | 138 -> (* setfsuid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setfsuid (138)"))
	 | 139 -> (* setfsgid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setfsgid (139)"))
	 | 140 -> (* _llseek *)
	     let (ebx, ecx, edx, esi, edi) = read_5_regs () in
	     let fd = Int64.to_int ebx and
		 off_high = ecx and
		 off_low = edx and
		 resultp = esi and
		 whence = Int64.to_int edi in
	     let offset = Int64.logor off_low (Int64.shift_left off_high 32) in
	       if !opt_trace_syscalls then
		 Printf.printf "_llseek(%d, %Ld, 0x%08Lx, %d)"
		   fd offset resultp whence;
	       self#sys__llseek fd offset resultp whence
	 | 141 -> (* getdents *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getdents (141)"))
	 | 142 -> (* _newselect *)
	     let (ebx, ecx, edx, esi, edi) = read_5_regs () in
	     let nfds = Int64.to_int ebx and
		 readfds = ecx and
		 writefds = edx and
		 exceptfds = esi and
		 timeout = edi in
	       if !opt_trace_syscalls then
		 Printf.printf "select(%d, 0x%08Lx, 0x%08Lx, 0x%08Lx, 0x%08Lx)"
		   nfds readfds writefds exceptfds timeout;
	       self#sys_select nfds readfds writefds exceptfds timeout
	 | 143 -> (* flock *)
	     raise (UnhandledSysCall( "Unhandled Linux system call flock (143)"))
	 | 144 -> (* msync *)
	     raise (UnhandledSysCall( "Unhandled Linux system call msync (144)"))
	 | 145 -> (* readv *)
	     raise (UnhandledSysCall( "Unhandled Linux system call readv (145)"))
	 | 146 -> (* writev *)
	     let (ebx, ecx, edx) = read_3_regs () in
	     let fd  = Int64.to_int ebx and
		 iov = ecx and
		 cnt = Int64.to_int edx in
	       if !opt_trace_syscalls then
		 Printf.printf "writev(%d, 0x%08Lx, %d)" fd iov cnt;
	       self#sys_writev fd iov cnt
	 | 147 -> (* getsid *)
	     if !opt_trace_syscalls then
	       Printf.printf "getsid()";
	     self#sys_getsid ()
	 | 148 -> (* fdatasync *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fdatasync (148)"))
	 | 149 -> (* _sysctl *)
	     raise (UnhandledSysCall( "Unhandled Linux system call _sysctl (149)"))
	 | 150 -> (* mlock *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mlock (150)"))
	 | 151 -> (* munlock *)
	     raise (UnhandledSysCall( "Unhandled Linux system call munlock (151)"))
	 | 152 -> (* mlockall *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mlockall (152)"))
	 | 153 -> (* munlockall *)
	     raise (UnhandledSysCall( "Unhandled Linux system call munlockall (153)"))
	 | 154 -> (* sched_setparam *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_setparam (154)"))
	 | 155 -> (* sched_getparam *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_getparam (155)"))
	 | 156 -> (* sched_setscheduler *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_setscheduler (156)"))
	 | 157 -> (* sched_getscheduler *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_getscheduler (157)"))
	 | 158 -> (* sched_yield *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_yield (158)"))
	 | 159 -> (* sched_get_priority_max *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_get_priority_max (159)"))
	 | 160 -> (* sched_get_priority_min *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_get_priority_min (160)"))
	 | 161 -> (* sched_rr_get_interval *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_rr_get_interval (161)"))
	 | 162 -> (* nanosleep *)
	     raise (UnhandledSysCall( "Unhandled Linux system call nanosleep (162)"))
	 | 163 -> (* mremap *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mremap (163)"))
	 | 164 -> (* setresuid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setresuid (164)"))
	 | 165 -> (* getresuid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getresuid (165)"))
	 | 166 -> (* vm86 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call vm86 (166)"))
	 | 167 -> (* query_module *)
	     raise (UnhandledSysCall( "Unhandled Linux system call query_module (167)"))
	 | 168 -> (* poll *)
	     raise (UnhandledSysCall( "Unhandled Linux system call poll (168)"))
	 | 169 -> (* nfsservctl *)
	     raise (UnhandledSysCall( "Unhandled Linux system call nfsservctl (169)"))
	 | 170 -> (* setresgid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setresgid (170)"))
	 | 171 -> (* getresgid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getresgid (171)"))
	 | 172 -> (* prctl *)
	     raise (UnhandledSysCall( "Unhandled Linux system call prctl (172)"))
	 | 173 -> (* rt_sigreturn *)
	     raise (UnhandledSysCall( "Unhandled Linux system call rt_sigreturn (173)"))
	 | 174 -> (* rt_sigaction *)
	     let (ebx, ecx, edx, esi) = read_4_regs () in
	     let signum = Int64.to_int ebx and
		 newbuf = ecx and
		 oldbuf = edx and
		 setlen = Int64.to_int esi in
	       if !opt_trace_syscalls then
		 Printf.printf "rt_sigaction(%d, 0x%08Lx, 0x%08Lx, %d)"
		   signum newbuf oldbuf setlen;
	       self#sys_rt_sigaction signum newbuf oldbuf setlen
	 | 175 -> (* rt_sigprocmask *)
	     let (ebx, ecx, edx, esi) = read_4_regs () in
	     let how    = Int64.to_int ebx and
		 newset = ecx and
		 oldset = edx and
		 setlen = Int64.to_int esi in
	       if !opt_trace_syscalls then
		 Printf.printf "rt_sigprocmask(%d, 0x%08Lx, 0x%08Lx, %d)"
		   how newset oldset setlen;
	       self#sys_rt_sigprocmask how newset oldset setlen
	 | 176 -> (* rt_sigpending *)
	     raise (UnhandledSysCall( "Unhandled Linux system call rt_sigpending (176)"))
	 | 177 -> (* rt_sigtimedwait *)
	     raise (UnhandledSysCall( "Unhandled Linux system call rt_sigtimedwait (177)"))
	 | 178 -> (* rt_sigqueueinfo *)
	     raise (UnhandledSysCall( "Unhandled Linux system call rt_sigqueueinfo (178)"))
	 | 179 -> (* rt_sigsuspend *)
	     raise (UnhandledSysCall( "Unhandled Linux system call rt_sigsuspend (179)"))
	 | 180 -> (* pread64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call pread64 (180)"))
	 | 181 -> (* pwrite64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call pwrite64 (181)"))
	 | 182 -> (* chown *)
	     raise (UnhandledSysCall( "Unhandled Linux system call chown (182)"))
	 | 183 -> (* getcwd *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getcwd (183)"))
	 | 184 -> (* capget *)
	     raise (UnhandledSysCall( "Unhandled Linux system call capget (184)"))
	 | 185 -> (* capset *)
	     raise (UnhandledSysCall( "Unhandled Linux system call capset (185)"))
	 | 186 -> (* sigaltstack *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sigaltstack (186)"))
	 | 187 -> (* sendfile *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sendfile (187)"))
	 | 188 -> (* getpmsg *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getpmsg (188)"))
	 | 189 -> (* putpmsg *)
	     raise (UnhandledSysCall( "Unhandled Linux system call putpmsg (189)"))
	 | 190 -> (* vfork *)
	     raise (UnhandledSysCall( "Unhandled Linux system call vfork (190)"))
	 | 191 -> (* ugetrlimit *)
	     let (ebx, ecx) = read_2_regs () in
	     let rsrc = Int64.to_int ebx and
		 buf  = ecx in
	       if !opt_trace_syscalls then
		 Printf.printf "ugetrlimit(%d, 0x%08Lx)" rsrc buf;
	       self#sys_ugetrlimit rsrc buf
	 | 192 -> (* mmap2 *)
	     let (ebx, ecx, edx, esi, edi, ebp) = read_6_regs () in
	     let addr     = ebx and
		 length   = ecx and
		 prot     = edx and
		 flags    = esi and
		 fd       = Int64.to_int edi and
		 pgoffset = Int64.to_int ebp in
	       if !opt_trace_syscalls then
		 Printf.printf "mmap2(0x%08Lx, %Ld, 0x%Lx, 0x%0Lx, %d, %d)"
		   addr length prot flags fd pgoffset;
	       self#sys_mmap2 addr length prot flags fd pgoffset
	 | 193 -> (* truncate64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call truncate64 (193)"))
	 | 194 -> (* ftruncate64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ftruncate64 (194)"))
	 | 195 -> (* stat64 *)
	     let (ebx, ecx) = read_2_regs () in
	     let path_buf = ebx and
		 buf_addr = ecx in
	     let path = fm#read_cstr path_buf in
	       if !opt_trace_syscalls then
		 Printf.printf "stat64(\"%s\", 0x%08Lx)" path buf_addr;
	       self#sys_stat64 path buf_addr
	 | 196 -> (* lstat64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lstat64 (196)"))
	 | 197 -> (* fstat64 *)
	     let (ebx, ecx) = read_2_regs () in
	     let fd = Int64.to_int ebx and
		 buf_addr = ecx in
	       if !opt_trace_syscalls then
		 Printf.printf "fstat64(%d, 0x%08Lx)" fd buf_addr;
	       self#sys_fstat64 fd buf_addr
	 | 198 -> (* lchown32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lchown32 (198)"))
	 | 199 -> (* getuid32 *)
	     if !opt_trace_syscalls then
	       Printf.printf "getuid32()";
	     self#sys_getuid32 ()
	 | 200 -> (* getgid32 *)
	     if !opt_trace_syscalls then
	       Printf.printf "getgid32()";
	     self#sys_getgid32 ()
	 | 201 -> (* geteuid32 *)
	     if !opt_trace_syscalls then
	       Printf.printf "geteuid32()";
	     self#sys_geteuid32 ()
	 | 202 -> (* getegid32 *)
	     if !opt_trace_syscalls then
	       Printf.printf "getegid32()";
	     self#sys_getegid32 ()
	 | 203 -> (* setreuid32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setreuid32 (203)"))
	 | 204 -> (* setregid32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setregid32 (204)"))
	 | 205 -> (* getgroups32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getgroups32 (205)"))
	 | 206 -> (* setgroups32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setgroups32 (206)"))
	 | 207 -> (* fchown32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fchown32 (207)"))
	 | 208 -> (* setresuid32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setresuid32 (208)"))
	 | 209 -> (* getresuid32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getresuid32 (209)"))
	 | 210 -> (* setresgid32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setresgid32 (210)"))
	 | 211 -> (* getresgid32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getresgid32 (211)"))
	 | 212 -> (* chown32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call chown32 (212)"))
	 | 213 -> (* setuid32 *)
	     let ebx = read_1_reg () in
	     let uid = Int64.to_int ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "setuid32(%d)" uid;
	       self#sys_setuid32 uid
	 | 214 -> (* setgid32 *)
	     let ebx = read_1_reg () in
	     let gid = Int64.to_int ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "setgid32(%d)" gid;
	       self#sys_setgid32 gid
	 | 215 -> (* setfsuid32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setfsuid32 (215)"))
	 | 216 -> (* setfsgid32 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setfsgid32 (216)"))
	 | 217 -> (* pivot_root *)
	     raise (UnhandledSysCall( "Unhandled Linux system call pivot_root (217)"))
	 | 218 -> (* mincore *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mincore (218)"))
	 | 219 -> (* madvise *)
	     raise (UnhandledSysCall( "Unhandled Linux system call madvise (219)"))
	 | 220 -> (* getdents64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getdents64 (220)"))
	 | 221 -> (* fcntl64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fcntl64 (221)"))
	 | 224 -> (* gettid *)
	     if !opt_trace_syscalls then
	       Printf.printf "gettid()";
	     self#sys_gettid 
	 | 225 -> (* readahead *)
	     raise (UnhandledSysCall( "Unhandled Linux system call readahead (225)"))
	 | 226 -> (* setxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call setxattr (226)"))
	 | 227 -> (* lsetxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lsetxattr (227)"))
	 | 228 -> (* fsetxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fsetxattr (228)"))
	 | 229 -> (* getxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getxattr (229)"))
	 | 230 -> (* lgetxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lgetxattr (230)"))
	 | 231 -> (* fgetxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fgetxattr (231)"))
	 | 232 -> (* listxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call listxattr (232)"))
	 | 233 -> (* llistxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call llistxattr (233)"))
	 | 234 -> (* flistxattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call flistxattr (234)"))
	 | 235 -> (* removexattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call removexattr (235)"))
	 | 236 -> (* lremovexattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lremovexattr (236)"))
	 | 237 -> (* fremovexattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fremovexattr (237)"))
	 | 238 -> (* tkill *)
	     raise (UnhandledSysCall( "Unhandled Linux system call tkill (238)"))
	 | 239 -> (* sendfile64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sendfile64 (239)"))
	 | 240 -> (* futex *)
	     let (ebx, ecx, edx, esi, edi, ebp) = read_6_regs () in
	     let uaddr    = ebx and
		 op       = Int64.to_int ecx and
		 value    = edx and
		 timebuf  = esi and
		 uaddr2   = edi and
		 val3     = ebp in
	       if !opt_trace_syscalls then
		 Printf.printf "futex(0x%08Lx, %d, %Ld, 0x%08Lx, 0x%08Lx, %Ld)"
		   uaddr op value timebuf uaddr2 val3;
	       self#sys_futex uaddr op value timebuf uaddr2 val3
	 | 241 -> (* sched_setaffinity *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_setaffinity (241)"))
	 | 242 -> (* sched_getaffinity *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sched_getaffinity (242)"))
	 | 243 -> (* set_thread_area *)
	     let ebx = read_1_reg () in
	     let uinfo = ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "set_thread_area(0x%08Lx)" uinfo;
	       self#sys_set_thread_area uinfo
	 | 244 -> (* get_thread_area *)
	     raise (UnhandledSysCall( "Unhandled Linux system call get_thread_area (244)"))
	 | 245 -> (* io_setup *)
	     raise (UnhandledSysCall( "Unhandled Linux system call io_setup (245)"))
	 | 246 -> (* io_destroy *)
	     raise (UnhandledSysCall( "Unhandled Linux system call io_destroy (246)"))
	 | 247 -> (* io_getevents *)
	     raise (UnhandledSysCall( "Unhandled Linux system call io_getevents (247)"))
	 | 248 -> (* io_submit *)
	     raise (UnhandledSysCall( "Unhandled Linux system call io_submit (248)"))
	 | 249 -> (* io_cancel *)
	     raise (UnhandledSysCall( "Unhandled Linux system call io_cancel (249)"))
	 | 250 -> (* fadvise64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fadvise64 (250)"))
	 | 252 -> (* exit_group *)
	     let ebx = read_1_reg () in
	     let status = ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "exit_group(%Ld) (no return)\n" status;
	       self#sys_exit_group status
	 | 253 -> (* lookup_dcookie *)
	     raise (UnhandledSysCall( "Unhandled Linux system call lookup_dcookie (253)"))
	 | 254 -> (* epoll_create *)
	     raise (UnhandledSysCall( "Unhandled Linux system call epoll_create (254)"))
	 | 255 -> (* epoll_ctl *)
	     raise (UnhandledSysCall( "Unhandled Linux system call epoll_ctl (255)"))
	 | 256 -> (* epoll_wait *)
	     raise (UnhandledSysCall( "Unhandled Linux system call epoll_wait (256)"))
	 | 257 -> (* remap_file_pages *)
	     raise (UnhandledSysCall( "Unhandled Linux system call remap_file_pages (257)"))
	 | 258 -> (* set_tid_address *)
	     let ebx = read_1_reg () in
	     let addr = ebx in
	       if !opt_trace_syscalls then
		 Printf.printf "set_tid_address(0x08%Lx)" addr;
	       self#sys_set_tid_address addr
	 | 259 -> (* timer_create *)
	     raise (UnhandledSysCall( "Unhandled Linux system call timer_create (259)"))
	 | 260 -> (* timer_settime *)
	     raise (UnhandledSysCall( "Unhandled Linux system call timer_settime (260)"))
	 | 261 -> (* timer_gettime *)
	     raise (UnhandledSysCall( "Unhandled Linux system call timer_gettime (261)"))
	 | 262 -> (* timer_getoverrun *)
	     raise (UnhandledSysCall( "Unhandled Linux system call timer_getoverrun (262)"))
	 | 263 -> (* timer_delete *)
	     raise (UnhandledSysCall( "Unhandled Linux system call timer_delete (263)"))
	 | 264 -> (* clock_settime *)
	     raise (UnhandledSysCall( "Unhandled Linux system call clock_settime (264)"))
	 | 265 -> (* clock_gettime *)
	     let (ebx, ecx) = read_2_regs () in
	     let clkid = Int64.to_int ebx and
		 timep = ecx in
	       if !opt_trace_syscalls then
		 Printf.printf "clock_gettime(%d, 0x08%Lx)" clkid timep;
	       self#sys_clock_gettime clkid timep
	 | 266 -> (* clock_getres *)
	     raise (UnhandledSysCall( "Unhandled Linux system call clock_getres (266)"))
	 | 267 -> (* clock_nanosleep *)
	     raise (UnhandledSysCall( "Unhandled Linux system call clock_nanosleep (267)"))
	 | 268 -> (* statfs64 *)
	     let (ebx, ecx, edx) = read_3_regs () in
	     let path_buf = ebx and
		 buf_len = Int64.to_int ecx and
		 struct_buf = edx in
	     let path = fm#read_cstr path_buf in
	       if !opt_trace_syscalls then
		 Printf.printf "statfs64(\"%s\", %d, 0x%08Lx)"
		   path buf_len struct_buf;
	       self#sys_statfs64 path buf_len struct_buf
	 | 269 -> (* fstatfs64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fstatfs64 (269)"))
	 | 270 -> (* tgkill *)
	     raise (UnhandledSysCall( "Unhandled Linux system call tgkill (270)"))
	 | 271 -> (* utimes *)
	     raise (UnhandledSysCall( "Unhandled Linux system call utimes (271)"))
	 | 272 -> (* fadvise64_64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fadvise64_64 (272)"))
	 | 273 -> (* vserver *)
	     raise (UnhandledSysCall( "Unhandled Linux system call vserver (273)"))
	 | 274 -> (* mbind *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mbind (274)"))
	 | 275 -> (* get_mempolicy *)
	     raise (UnhandledSysCall( "Unhandled Linux system call get_mempolicy (275)"))
	 | 276 -> (* set_mempolicy *)
	     raise (UnhandledSysCall( "Unhandled Linux system call set_mempolicy (276)"))
	 | 277 -> (* mq_open *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mq_open (277)"))
	 | 278 -> (* mq_unlink *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mq_unlink (278)"))
	 | 279 -> (* mq_timedsend *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mq_timedsend (279)"))
	 | 280 -> (* mq_timedreceive *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mq_timedreceive (280)"))
	 | 281 -> (* mq_notify *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mq_notify (281)"))
	 | 282 -> (* mq_getsetattr *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mq_getsetattr (282)"))
	 | 283 -> (* kexec_load *)
	     raise (UnhandledSysCall( "Unhandled Linux system call kexec_load (283)"))
	 | 284 -> (* waitid *)
	     raise (UnhandledSysCall( "Unhandled Linux system call waitid (284)"))
	 | 286 -> (* add_key *)
	     raise (UnhandledSysCall( "Unhandled Linux system call add_key (286)"))
	 | 287 -> (* request_key *)
	     raise (UnhandledSysCall( "Unhandled Linux system call request_key (287)"))
	 | 288 -> (* keyctl *)
	     raise (UnhandledSysCall( "Unhandled Linux system call keyctl (288)"))
	 | 289 -> (* ioprio_set *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ioprio_set (289)"))
	 | 290 -> (* ioprio_get *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ioprio_get (290)"))
	 | 291 -> (* inotify_init *)
	     raise (UnhandledSysCall( "Unhandled Linux system call inotify_init (291)"))
	 | 292 -> (* inotify_add_watch *)
	     raise (UnhandledSysCall( "Unhandled Linux system call inotify_add_watch (292)"))
	 | 293 -> (* inotify_rm_watch *)
	     raise (UnhandledSysCall( "Unhandled Linux system call inotify_rm_watch (293)"))
	 | 294 -> (* migrate_pages *)
	     raise (UnhandledSysCall( "Unhandled Linux system call migrate_pages (294)"))
	 | 295 -> (* openat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call openat (295)"))
	 | 296 -> (* mkdirat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mkdirat (296)"))
	 | 297 -> (* mknodat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call mknodat (297)"))
	 | 298 -> (* fchownat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fchownat (298)"))
	 | 299 -> (* futimesat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call futimesat (299)"))
	 | 300 -> (* fstatat64 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fstatat64 (300)"))
	 | 301 -> (* unlinkat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call unlinkat (301)"))
	 | 302 -> (* renameat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call renameat (302)"))
	 | 303 -> (* linkat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call linkat (303)"))
	 | 304 -> (* symlinkat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call symlinkat (304)"))
	 | 305 -> (* readlinkat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call readlinkat (305)"))
	 | 306 -> (* fchmodat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fchmodat (306)"))
	 | 307 -> (* faccessat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call faccessat (307)"))
	 | 308 -> (* pselect6 *)
	     raise (UnhandledSysCall( "Unhandled Linux system call pselect6 (308)"))
	 | 309 -> (* ppoll *)
	     raise (UnhandledSysCall( "Unhandled Linux system call ppoll (309)"))
	 | 310 -> (* unshare *)
	     raise (UnhandledSysCall( "Unhandled Linux system call unshare (310)"))
	 | 311 -> (* set_robust_list *)
	     let (ebx, ecx) = read_2_regs () in
	     let addr = ebx and
		 len  = ecx in
	       if !opt_trace_syscalls then
		 Printf.printf "set_robust_list(0x08%Lx, %Ld)" addr len;
	       self#sys_set_robust_list addr len
	 | 312 -> (* get_robust_list *)
	     raise (UnhandledSysCall( "Unhandled Linux system call get_robust_list (312)"))
	 | 313 -> (* splice *)
	     raise (UnhandledSysCall( "Unhandled Linux system call splice (313)"))
	 | 314 -> (* sync_file_range *)
	     raise (UnhandledSysCall( "Unhandled Linux system call sync_file_range (314)"))
	 | 315 -> (* tee *)
	     raise (UnhandledSysCall( "Unhandled Linux system call tee (315)"))
	 | 316 -> (* vmsplice *)
	     raise (UnhandledSysCall( "Unhandled Linux system call vmsplice (316)"))
	 | 317 -> (* move_pages *)
	     raise (UnhandledSysCall( "Unhandled Linux system call move_pages (317)"))
	 | 318 -> (* getcpu *)
	     raise (UnhandledSysCall( "Unhandled Linux system call getcpu (318)"))
	 | 319 -> (* epoll_pwait *)
	     raise (UnhandledSysCall( "Unhandled Linux system call epoll_pwait (319)"))
	 | 320 -> (* utimensat *)
	     raise (UnhandledSysCall( "Unhandled Linux system call utimensat (320)"))
	 | 321 -> (* signalfd *)
	     raise (UnhandledSysCall( "Unhandled Linux system call signalfd (321)"))
	 | 322 -> (* timerfd_create *)
	     raise (UnhandledSysCall( "Unhandled Linux system call timerfd_create (322)"))
	 | 323 -> (* eventfd *)
	     raise (UnhandledSysCall( "Unhandled Linux system call eventfd (323)"))
	 | 324 -> (* fallocate *)
	     raise (UnhandledSysCall( "Unhandled Linux system call fallocate (324)"))
	 | 325 -> (* timerfd_settime *)
	     raise (UnhandledSysCall( "Unhandled Linux system call timerfd_settime (325)"))
	 | 326 -> (* timerfd_gettime *)
	     raise (UnhandledSysCall( "Unhandled Linux system call timerfd_gettime (326)"))
	 | _ ->
	     Printf.printf "Unhandled system call %d\n" syscall_num;
	     failwith "Unhandled Linux system call");
    if !opt_trace_syscalls then
      let ret_val = fm#get_word_var R_EAX in
	Printf.printf " = %Ld (0x%08Lx)\n" (fix_s32 ret_val) ret_val;
	flush stdout

  method handle_special str =
    try
      match str with
	| "int 0x80" ->
	    self#handle_linux_syscall ();
	    Some []
	| "sysenter" ->
	    let sysenter_eip = fm#get_word_var R_EIP in
	    let sysexit_eip = (Int64.logor 0x430L
				 (Int64.logand 0xfffff000L sysenter_eip)) in
	    let label = "pc_0x" ^ (Printf.sprintf "%08Lx" sysexit_eip) in
	      self#handle_linux_syscall ();
	      Some [V.Jmp(V.Name(label))]
	| _ -> None
    with
	NotConcrete(_) -> raise SymbolicSyscall
end
