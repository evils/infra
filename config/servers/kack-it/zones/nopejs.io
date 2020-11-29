$TTL 120
$ORIGIN nopejs.io.
@    IN    SOA    ns1.h4ck.space. foo.h4ck.space. (
                2017032201 ; Serial - date by convention
                10800      ; Refresh
                600        ; Retry
                604800     ; Expire
                600        ; Negative cache TTL
)

        IN      NS      ns1.h4ck.space.
        IN      NS      ns2.h4ck.space.
        IN      AAAA    2a01:4f8:211:13c1::11
        IN      MX      10 mx.h4ck.space.
