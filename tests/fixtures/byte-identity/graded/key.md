#### K1 blocking - the retry path drops the write
The early return skips write(x).
#### K2 blocking - the token is logged
A credential reaches the log.
#### K3 should-fix - the counter is never reset
count grows without bound.
