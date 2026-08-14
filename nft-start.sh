#!/bin/bash
nft add table inet zapret
nft add chain inet zapret output "{ type filter hook output priority -1; }"
nft add rule inet zapret output tcp dport "{ 80, 443 }" queue num 200 bypass
