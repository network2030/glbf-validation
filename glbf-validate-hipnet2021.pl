#!/opt/local/bin/perl
# Copyright 2020-2021 Futurewei Technologies, Inc.  All rights reserved
# Toerless Eckert
#
# Simple (hacked) perl script for time-discrete simulation of gLBF validation scenarios as
# explained in the HiPNET 2021 gLBF paper. See:
# https://www.github.com/network2030/glbf-validation
#
$\="\n";

use Data::Dumper;

sub ceil {
    my($i) = @_;
    my($iout) = int($i);
    if($i > $iout) {
        $iout++;
    }
    return $iout;
}

$linkrate = 100000000; # 100 Mbps links -> one bit every 10 nsec.
$linkrate = 30000000; # 100 Mbps links -> one bit every 10 nsec.
# $linkrate = 29000000;
$nsec = 1000000000;    # We use nsec resolution for all our counters
$runtime = 1 * $nsec;  # 1 second runtime

## outgoing interface queue q
## fifo sorted by packet arrival time
## had of queue of quue is arrival time 0

sub enqueue {
    my($q, $p) = @_;
    my($qp);
    my($qq) = $q;

    # print "enqueue:";
    # print "--------";
    # print "q -> " . Dumper($q);
    # print "p -> " . Dumper($p);

    #
    # Skip past earlier packets in the queue
    #
    while($qq && $qq->{p} && ($p->{atime} >= $qq->{atime})) {
        $qp = $qq;
        $qq = $qq->{next};
        # print "YES while";
    }

    # printf "EXIT: qq=%d, qq->{p}=%d, p->{atime}=%d >= qq->{atime}=%d\n",
    #         $qq, $qq->{p}, $p->{atime}, $qq->{atime};

    # Our packet goes first, need to update $q
    if(!$qp) {
        # print "YES packet goes in first";
        if($q->{p}) {
            # print "YES there is a packet in the queue";
            # Most complex option: need to copy packet into existing packet place 
            # because we can not change the pointer to this first packet as its
            # only passed by value to this function
            my($qe);
            $qe->{atime} = $q->{atime};
            $qe->{p} = $q->{p};
            $qe->{next} = $q->{next};
            $q->{next} = $qe;
        }
        $q->{atime} = $p->{atime};
        $q->{p} = $p;
    } else {
        my($qe);
        $qe->{atime} = $p->{atime};
        $qe->{p} = $p;
        $qe->{next} = $qq;

        $qp->{next} = $qe;
    }
}

sub print_queue {
    my($q) = @_;

    printf( "Flow:Paket   arrival time\n");
    while($q->{p}) {
        printf( "F%03d:P%05d %8d... %8d= +%9d glbf= %8d/%4d delta= %d\n",
                $q->{p}->{fnum}, $q->{p}->{pnum},
                $q->{p}->{atime}, $q->{p}->{stime},
                $q->{p}->{stime} - $q->{p}->{atime},
                $q->{p}->{glbfdelay}, $q->{p}->{maxbuf},
                $q->{p}->{delta});
        $q = $q->{next};
    }
}

# verify that all packets in the queue are actually in
# gLBF processing order.

sub verify_queue_glbf {
    my($q, $maxbuf) = @_;
    my($npackets) = 0;
    my($last_atime) = 0;
    my($last_ptime) = 0;

    while($q->{p}) {
        $atime = $q->{p}->{atime};
        $ptime = $atime + $q->{p}->{glbfdelay};
        if($atime < $last_atime) {
            print "VERIFY: atime error: last= $last_atime, current= $atime";
        }
        $last_atime = $atime;
        if($ptime < $last_ptime) {
            print "VERIFY: ptime error: last= $last_ptime, current= $ptime";
        }
        $last_ptime = $ptime;
        $n++;
        $q = $q->{next};
    }
    printf "VERIFY: npackets= $npackets, queue= %s\n", $q->{name};
}

sub count_queue {
    my($when, $q) = @_;
    my($n) = 0;

    while($q->{p}) {
        $n++;
        $q = $q->{next};
    }
    printf "count_queue $when: $n\n", $q->{name};
    return $n;
}

## Send packet across link:
## emulate link, transferring packets from $q1 on sender router to $q2 on receiver router
## copying packets, calculating arrival time of packet from send time.

sub send_across_link {
    my($q1, $linkrate, $q2, $fnum) = @_;

    printf( "Transfering flow $fnum from queue %s to queue %s with linkrate $linkrate\n", $q1->{name}, $q2->{name});
    while($q1->{p}) {
        ## 
        ## how to transfer packets from one queue ("router") to another queue ("router"):
        ## We assume the arrival time is what we can measure in reality: the time
        ## the last bit of a packet was received by the router. Likewise, the send time
        ## is what we have control about: the time the link starts sending the first
        ## bit of the packet. Therefore, when transferrring a packet from the queue of
        ## one router to the next, we need to add the serialization time across the link
        ##
        # printf( "F%03d:P%05d (%d): atime %12d -> stime=%12d level=%d\n",
        #         $q1->{p}->{fnum}, $q1->{p}->{pnum}, $q1->{p}->{atime},
        #         $q1->{atime},
        #         $q1->{p}->{stime}, $q1->{p}->{level});

        my $fnum2 = $q1->{p}->{fnum};
        if($fnum2 == $fnum) {
            my $psize = $f->{$fnum2}->{psize};
            my $p2;
      
            $p2->{fnum}  = $fnum2;
            $p2->{psize} = $psize;
            $p2->{pnum}  = $q1->{p}->{pnum};

            ## Transfer packet across link by calculating arrival time from send time
            ## and link speed. 'ceil' is important here, or else gLBF can not prevent
            ## minute level errors because we effectively are sending packets to fast
            ## bcause we are underestimating the arrival time vs. the actual length
            ## of the packet. Aka: this is the first point where errors introduced
            ## by link variations can be seen in th results (e.g.: by removing ceil),
            
            $p2->{atime} = ceil($q1->{p}->{stime} + $psize * 8 * $nsec / $linkrate);

            $p2->{glbfdelay} = $q1->{p}->{glbfdelay};
            $p2->{maxbuf}    = $q1->{p}->{maxbuf};

            $p2->{sender_stime} = $q1->{p}->{stime};
            $p2->{sender_atime} = $q1->{p}->{atime};

            if($debug1) {
                my $n = count_queue("before", $q2);
                if($n == 2) {
                    print Dumper($q2);
                    exit(0);
                }
            }
            enqueue($q2, $p2);
            if($debug1) {
                count_queue("after", $q2);
            }
        }

        $q1 = $q1->{next};
    }
}

##
## Apply gLBF delay to all packets in $q1, copy packets into $q2
## arrival time of packet in $q2 will be the earliest processing time after glbfdelay
## 

sub glbf_delay {
    my($q1, $q2, $quiet) = @_;

    printf( "Applying gLBF delay to packets in %s, transferring them to '%s'\n", $q1->{name}, $q2->{name});
    while($q1->{p}) {

        my $p2;
        $p2->{psize}  = $q1->{p}->{psize};
        $p2->{fnum}   = $q1->{p}->{fnum};
        $p2->{pnum}   = $q1->{p}->{pnum};
        $p2->{atime}  = $q1->{p}->{atime} + $q1->{p}->{glbfdelay};
        $p2->{sender_stime} = $q1->{p}->{sender_stime};
        $p2->{sender_atime} = $q1->{p}->{sender_atime};

        if(!$quiet) {
            my $linklat = $q1->{p}->{atime} - $q1->{p}->{sender_stime};  
            my $linkbytes = $linklat * $linkrate / $nsec / 8;

            printf("gLBFdelay: F%03d:P%05d(%4d bytes) sndr: %8d +%8d= %8d --( %4d/ %4d )--> rcvr: %8d + %8d = %8d (%d:%d)\n",
                $q1->{p}->{fnum}, $q1->{p}->{pnum}, $p2->{psize},
                $q1->{p}->{sender_atime},   $q1->{p}->{sender_stime} - $q1->{p}->{sender_atime},    $q1->{p}->{sender_stime},
                $linklat, $linkbytes,
                $q1->{p}->{atime}, $q1->{p}->{glbfdelay}, $p2->{atime},
                $q1->{p}->{maxbuf}, $p2->{atime} - $q1->{p}->{sender_atime}
                );
        }

        enqueue($q2, $p2);
        $q1 = $q1->{next};
    }
}

sub list_queue {
    my($q) = @_;
    my($qp) = $q;

    printf( "DQ starting\n");
    # calculate queue depth and resulting latency of packet
    $t = 0;
    $qsize = 0; # bytes

    while($q->{p}) {
        my($p) = $q->{p};

        # $t is our current next dequeue time
        # if it is earlier than p->{atime} it means the queue is empty and
        # we can skip $t to p->{atime}
        if($t < $p->{atime}) {
            # printf("                                               %12d IDLE\n", $p->{atime} - $t);
            $t = $p->{atime};
        }

        printf( "DQ F%03d:P%04d atime=%010d dtime=%010d  %10d LATENCY\n",
                $p->{fnum}, $p->{pnum}, $p->{atime},
                $t, ($t - $p->{atime}));

        # calculate minimum next t:
        # we need linkrate in bits / nsec for result to be in nsec,
        # but we want to try to stay within 64 bit int in our calculation

        $t += $p->{psize} * 8 * $nsec / $linkrate;
        $q = $q->{next};
    }
}

# Verify that all flows in the queue comply with their envelope
# If $atime = 1, check arival time, else send time

sub verify_queue_envelope {
    my($qh, $f, $atime, $quiet) = @_;
    my($q) = $qh;

    my($flow, $rate, $psize, $bsize, $level, $levelt, $dt);

    my($minlevel) = 99999;
    my($maxlevel) = 0;
    my($levelerror) = 0;
    my($npackets) = 0;
    my($minlatency) = 9999999999;
    my($maxlatency) = 0;
    my $latency;
    
    # reset level/levelt;
    foreach my $fnum (keys(%$f)) {
        $f->{$fnum}->{level} = $f->{$fnum}->{bsize};
        $f->{$fnum}->{levelt} = 0;
    }

    # examine all packets
    while($q->{p}) {
        my($p) = $q->{p};

        my $flow = $p->{fnum};
        my $rate = $f->{$flow}->{rate};
        my $psize = $f->{$flow}->{psize};
        my $bsize = $f->{$flow}->{bsize};
        my $level = $f->{$flow}->{level};
        my $levelt = $f->{$flow}->{levelt};
        my $t = $atime ? $p->{atime} : $p->{stime};

        if($atime) {
            $latency = $q->{p}->{atime} - $q->{p}->{sender_atime};
        } else {
            $latency = $q->{p}->{stime} - $q->{p}->{atime};
        }
        $maxlatency = $latency if $latency > $maxlatency;
        $minlatency = $latency if $latency < $minlatency;
       
        # Calculate if/how-much the packet is within its flow envelope
        $dt = $t - $levelt;
        $level += int($dt * $rate / $nsec);
        if($level > $bsize) {
            $level = $bsize;
        }
        $level -= $psize * 8;
        $p->{level} = $level;
    
        # Update flow policer, copy level into packet
        $f->{$flow}->{level} = $level;
        $f->{$flow}->{levelt} = $t;
    
        $minlevel = $level if $level < $minlevel;
        $maxlevel = $level if $level > $maxlevel;

        if($level < 0) {
            if(!$quiet) {
                printf( "%010d LEVELERROR %s F%03d:P%04d level= %6d\n", $t, $atime ? "atime" : "stime", $p->{fnum}, $p->{pnum}, $level);
            }
            $levelerror++;
        }
        $q = $q->{next};
    }
    printf( "Levelcheck %s '%s' time, latency=%d...%d, level: %d... %d, levelerrors: %d\n",
             $qh->{name}, $atime ? "arrival" : "send",
             $minlatency, $maxlatency,
             $minlevel, $maxlevel, $levelerror);

    return $levelerror;
}

# send packet - and calculate statistics for it
# parameters $p - packet, $f - flows, $t - time packet is sent, $stats, $quiet

sub sendpacket {
    my($q, $p, $f, $quiet) = @_;
    my($flow, $rate, $psize, $bsize, $level, $levelt, $dt, $latency);

    $flow = $p->{fnum};
    $rate = $f->{$flow}->{rate};
    $psize = $f->{$flow}->{psize};
    $bsize = $f->{$flow}->{bsize};
    $level = $f->{$flow}->{level};
    $levelt = $f->{$flow}->{levelt};

    # Calculate if/how-much packet is within its flow envelope
    $dt = $p->{stime} - $levelt;
    $level += int($dt * $rate / $nsec);
    if($level > $bsize) {
        $level = $bsize;
    }
    $level -= $psize * 8;
    $p->{level} = $level;
    # Update flow policer, copy level into packet
    $f->{$flow}->{level} = $level;
    $f->{$flow}->{levelt} = $p->{stime};

    # Latency
    $p->{latency} = $latency = $p->{stime} - $p->{atime};

    # GLBF innovation step 1:
    # Calculate desired gLBFdelay on next hop:
    # Maximum time a packet could have in queue - actual latency experienced in queue:
    #  maxbuf is in units of bytes. Convert into nsec latency:

    # Excourse into gLBF operations:
    # We have a flow that is emitting packets of different sizes.
    # gLBF to have the desired result, the 

    # Basic operations of gLBF:
    #
    # +----------------------------------+          +----------------------------------+       
    # |gLBFdelay - X1 - FIFO gLBFmeasure |---link-->|gLBFdelay - X2 - FIFO gLBFmeasure |
    # +----------------------------------+          +----------------------------------+       
    #
    # When packets of a flow arrive at X1, we assume they have correct "shaping".
    # We therefore want to ensure that all packets of the flow arrive at X2 at
    # a fixed offset from X1: X2 = X1 + offset.
    #  offset = FIFO_delay + link_serialization + gLBFdelay
    #
    # Calculate the minimum offset for which we can make this work:
    #  gLBFdelay >= 0 - we can not delay negative
    #  FIFO_delay <= max_FIFO_delay - calculated from maximum buffer size of FIFO.
    #  link_serialization <= max_packet_link_serialization - for max packet size
    #  Assume we have FIFO_dela
    #
    # F007:P00630( 970 bytes) sndr: 486552000 + 1221839= 487773839 --( 258667/  970 )--> rcvr: 488032506 +  1986161 = 490018667 (-3)
    #                                           latency                                        q4:atime  + glbfdelay  q4r:atime
    #                              max - latency -                    258667

    # $glbf = $q->{maxbuf} * 8 * $nsec / $q->{linkrate} - $latency - p->{psize} * 8 * $nsec / $q->{linkrate};

    # Option 1:
    # $glbf = $q->{maxbuf} * 8 * $nsec / $q->{linkrate} - $latency - p->{psize} * 8 * $nsec / $q->{linkrate};
    # F001:P00001( 900 bytes) sndr:        0 +       0=        0 --( 240000/  900 )--> rcvr:   240000 +  2400000 =  2640000 (9000:2640000)
    # F001:P00002( 900 bytes) sndr:        0 +  240000=   240000 --( 240000/  900 )--> rcvr:   480000 +  2160000 =  2640000 (9000:2640000)
    # F001:P00003( 900 bytes) sndr:        0 +  480000=   480000 --( 240000/  900 )--> rcvr:   720000 +  1920000 =  2640000 (9000:2640000)
    # F002:P00001(1000 bytes) sndr:        0 +  720000=   720000 --( 266667/ 1000 )--> rcvr:   986667 +  1680000 =  2666667 (9000:2666667)
    # F002:P00002(1000 bytes) sndr:        0 +  986667=   986667 --( 266667/ 1000 )--> rcvr:  1253334 +  1413333 =  2666667 (9000:2666667)
    # F002:P00003(1000 bytes) sndr:        0 + 1253334=  1253334 --( 266667/ 1000 )--> rcvr:  1520001 +  1146666 =  2666667 (9000:2666667)
    # F003:P00001(1100 bytes) sndr:        0 + 1520001=  1520001 --( 293334/ 1100 )--> rcvr:  1813335 +   879999 =  2693334 (9000:2693334)
    # F003:P00002(1100 bytes) sndr:        0 + 1813335=  1813335 --( 293334/ 1100 )--> rcvr:  2106669 +   586665 =  2693334 (9000:2693334)
    # F003:P00003(1100 bytes) sndr:        0 + 2106669=  2106669 --( 293334/ 1100 )--> rcvr:  2400003 +   293331 =  2693334 (9000:2693334)

    # Option 1:
    # $glbf = $q->{maxbuf} * 8 * $nsec / $q->{linkrate} - $latency - $p->{psize} * 8 * $nsec / $q->{linkrate};

    # We did not account for the worst case packe in transit.
    # Let's do it:

    # The 'ceil' for the link transmission time needs to match the formula
    # used to calculae 'tnext' == transmission time across the link.
    $glbf = ceil(($q->{maxbuf} + 1100) * 8 * $nsec / $q->{linkrate}) - $latency - ceil($p->{psize} * 8 * $nsec / $q->{linkrate});

    $p->{glbfdelay} = $glbf;
    $p->{maxbuf} = $q->{maxbuf}; # XXX for debuging purposes only

    if(!$quiet) {
        printf( "%010d SEND          F%03d:P%04d qsize=                 %6d lat=%10d glbf= %d/%d level= %6d (after sending)\n",
             $p->{stime}, $p->{fnum}, $p->{pnum}, 
             $qsize, $latency, $glbf, $p->{maxbuf}, $level, $level < 0 ? " LEVELERROR" : "");

        # TTE: can not print tnext as we don't have it here
        # printf( "%010d SEND    F%03d:P%04d qsize=%6d lat=%10d  level= %6d (after sending) until %10d%s\n",
        #      $p->{stime}, $p->{fnum}, $p->{pnum}, $qsize, $latency, $level, $level < 0 ? " LEVELERROR" : "", $tnext);
    }

    $q->{stats}->{npackets}++;
    if($level < $q->{stats}->{minlevel}) {
        $q->{stats}->{minlevel} = $level;
        $q->{stats}->{minlevel_fnum} = $p->{fnum};
        $q->{stats}->{minlevel_pnum} = $p->{pnum};
    }
    if($latency > $q->{stats}->{maxlatency}) {
        $q->{stats}->{maxlatency} = $latency;
    }
    if($latency < $q->{stats}->{minlatency}) {
        $q->{stats}->{minlatency} = $latency;
    }
}

sub calc_maxbuf {
    my($qh) = @_;
    my($q) = $qh;

    my $maxbuf = 0;
    my %counted_fnum;
    while($q) {
        my $fnum = $q->{p}->{fnum};
        if($fnum && !$counted_fnum{$fnum}) {
            $maxbuf += $f->{$fnum}->{bsize} / 8;
            $counted_fnum{$fnum}++;
        }
        $q = $q->{next};
    }
    $qh->{maxbuf} = $maxbuf;
}

sub dequeue {
    my($q, $quiet, $explain, $q_glbf, $off) = @_;

    if(!$quiet) {
        printf( "DQ %s starting\n", $q->{name});
    }

    ##
    ## Prep section
    ##

    # Prep1:
    # Reset policers for all flows
    foreach my $fnum (keys(%$f)) {
        # print "FLOW: $fnum";
        $f->{$fnum}->{level} = $f->{$fnum}->{bsize};
        $f->{$fnum}->{levelt} = 0;
    }

    # Prep2:
    # Initialize stats
    $q->{stats} = 0;
    $q->{stats}->{npackets} = 0;
    $q->{stats}->{minlevel} = 999999;
    $q->{stats}->{minxlatency} = 999999;
    $q->{stats}->{maxlatency} = 0;
    $q->{stats}->{maxqsize} = 0;

    # Prep3:
    # Calculate theoretical maximum buffer size required for this dequeue run
    # by adding up the burst sizes of all flows in the queue

    calc_maxbuf($q);
    # printf "PREP3: maxbuf= %d\n", $q->{maxbuf};

    $q->{linkrate} = $linkrate;

    ##
    ## Dequeue packets loop
    ##

    my $q_send    = $q; # pointer for outer loop where we send packets
    my $q_receive = $q->{next}; # pointer for inner loop where we receive packets
    my $q_delay   = $q_glbf; # pointer to account for packets in gLBF delay buffer

    my $t = 0;
    # Sigh: keep them global so we can use them in sendpacket
    # my $qsize = 0;
    # my $gsize = 0;
    $qsize = 0;
    $gsize = 0;

    while($q_send) {

        my $p = $q_send->{p};

        # Check if the next packet we can send is later than $t.
        # If so, then we have to idle until then

        if($p->{atime} > $t) {
            # Nothing to send to interface until atime. Report idle time
            # printf( "%010d IDLE TO %10d, delta=%d qsize=%d%s\n",
            #          $t, $p->{atime}, ($p->{atime} - $t), $qsize, $qsize > 0 ? " ERROR1" : "");
            if(!$quiet) {
                printf( "%010d IDLE                     qsize=                  %6d\n", $t, $qsize);
            }
            $t = $p->{atime};
            # WRONG: $q_receive = $q_send->{next};
        }

        # Process packets for gLBF - just account them into $gsize

        while($q_glbf && defined($q_delay->{p}) && $q_delay->{p}->{atime} <= $t) {
        if(0 && !$quiet) {
             printf "In     RECEIVE1: q_glbf:%s, q_delay-{p}:%s, q_delay->{p}->{atime}=%d, t=%d\n",
                $q_glbf ? "1" : "0", defined($q_delay->{p}) ? "1" : "0", $q_delay->{p}->{atime}, $t;
        }
            if(!$quiet) {
                printf( "%010d gLBF RECEIVE1 F%03d:P%04d gsize= %6d + %4d = %6d, qsize= %6d, total= %6d\n", 
                     $t, $q_delay->{p}->{fnum}, $q_delay->{p}->{pnum},
                     $gsize, $q_delay->{p}->{psize}, $gsize + $q_delay->{p}->{psize}, $qsize, 
                     $gsize + $q_delay->{p}->{psize} + $qsize);
            }
            $gsize += $q_delay->{p}->{psize};
            $q_delay = $q_delay->{next};
        }
        if(0 && !$quiet) {
             printf "Exiting RECEIVE1: q_glbf:%s, q_delay-{p}:%s, q_delay->{p}->{atime}=%d, t=%d\n",
                $q_glbf ? "1" : "0", defined($q_delay->{p}) ? "1" : "0", $q_delay->{p}->{atime}, $t;
        }

        # Packet just arrived

        if($t == $p->{atime}) {

            # Should be no queue

            if($qsize) {
                # This should not happen.  # Just notice the error.
                # No attempt to recover. Results probably proken.
                printf( "%010d ERROR2            qsize=%6d\n", $t, $qsize);
            }

            # Enqueue packet, even though we will immediately dequeue it afterwards,
            # just to be correct. Don't bother trying to update maxbuffer though, not worth it.

            if($q_glbf) {
                if(!$quiet) {
                    printf( "%010d gLBF DEQUEUE  F%03d:P%04d gsize= %6d - %4d = %6d, qsize= %6d, total= %6d\n",
                             $t, $p->{fnum}, $p->{pnum},
                             $gsize, $p->{psize}, $gsize - $p->{psize},
                             $qsize,  $gsize - $p->{psize} + $qsize);
                }
                $gsize -= $p->{psize};
            }
            if(!$quiet) {
                printf( "%010d      ENQUEU2  F%03d:P%04d qsize= %6d + %4d = %6d, gsize= %6d, total= %6d\n",
                         $t, $p->{fnum}, $p->{pnum}, 
                         $qsize, $p->{psize}, $qsize + $p->{psize},
                         $gsize, $qsize + $p->{psize} + $gsize);
            }
            $qsize += $p->{psize};
            $q_receive = $q_send->{next};
        }

        # Send this packet

        if(!$quiet) {
            printf( "%010d      DEQUEUE  F%03d:P%04d qsize= %6d - %4d = %6d, gsize= %6d, total= %6d\n",
                          $t, $p->{fnum}, $p->{pnum}, 
                          $qsize, $p->{psize}, $qsize - $p->{psize},
                          $gsize, $qsize - $p->{psize} + $gsize);
        }
        $qsize -= $p->{psize};
        $p->{stime} = $t;
        sendpacket($q, $p, $f, $quiet);
        # printf "DEBUG: %d\n", $q_send->{p}->{glbfdelay};
        # WRONG: $q_receive = $q_send->{next};

        # Process packets up to the time the current packet is serialized.

        ## This needs to align with calculation of glbfdelay
        $tnext = ceil($t + $p->{psize} * 8 * $nsec / $linkrate); # XXX we could add more time here to space packets ???

        if(0 && !$quiet) {
            my $psize = $p->{psize};
            printf "TNEXT: t=$t, tnext=$tnext, psize=$psize, nsec=$nsec, linkrate=$linkrate\n";
        }

        if($q_glbf) {
            while(defined($q_delay->{p}) && $q_delay->{p}->{atime} < $tnext) {
                my $p2 = $q_delay->{p};

                if(!$quiet) {
                    printf( "%010d gLBF RECEIVE2 F%03d:P%04d gsize= %6d + %4d = %6d, qsize= %6d, total= %6d\n", 
                             $t, $p2->{fnum}, $p2->{pnum},
                             $gsize, $p2->{psize}, $gsize + $p2->{psize},
                             $qsize, $gsize + $p2->{psize} + $qsize);
                }
                $gsize += $p2->{psize};
                $q_delay = $q_delay->{next};
            }
        }

        while($q_receive && $q_receive->{p}->{atime} < $tnext) {

            # Enqueue $q_receive->{p}

            my($p2) = $q_receive->{p};
            my($t2) = $p2->{atime};
            my($p2size) = $p2->{psize};

            # If we are doing gLBF, then we need to unaccount the packet there 
            if($q_glbf) {
                if(!$quiet) {
                    printf( "%010d gLBF DEQUEUE  F%03d:P%04d gsize= %6d - %4d = %6d, qsize= %6d, total= %6d\n",
                             $t2, $p2->{fnum}, $p2->{pnum},
                             $gsize, $p2size, $gsize - $p2size,
                             $qsize,  $gsize - $p2size + $qsize);
                }
                $gsize -= $p2size;
            }

            if(!$quiet) {
                printf( "%010d      ENQUEUE  F%03d:P%04d qsize= %6d + %4d = %6d, gsize= %6d, total= %6d\n",
                             $t2, $p2->{fnum}, $p2->{pnum},
                             $qsize, $p2size, $qsize + $p2size,
                             $gsize, $gsize + $qsize + $p2size);
            }
            $qsize += $p2size;

            if($qsize > $q->{stats}->{maxqsize}) {
                $q->{stats}->{maxqsize} = $qsize;
            }
            $q_receive = $q_receive->{next};
        }

        $q_send = $q_send->{next};
        $t = $tnext;
    }

    ##
    ## Report result
    ##

    printf( "${explain}dequeue %s pkts= %d, maxq= %d (of %d%s free %d), latency=%d.. %d [nsec], minlevel= %d [bits], (packet F%dP%d)\n",
        $q->{name},
        $q->{stats}->{npackets},
        $q->{stats}->{maxqsize},
        $q->{maxbuf},
        $q->{stats}->{maxqsize} > $q->{maxbuf} ? " BUFFEROVERFLOW" : "",
        $q->{maxbuf} - $q->{stats}->{maxqsize},
        $q->{stats}->{minlatency},
        $q->{stats}->{maxlatency},
        $q->{stats}->{minlevel},
        $q->{stats}->{minlevel_fnum},
        $q->{stats}->{minlevel_pnum});
}

# gen_packets(queue, flow, smoooth)
# generate a sequence of packets with their sending timestamps
# according to the spec "flow" into "queue. Always send as
# much as the envolpe allows (rate, burst size).
#
# when smooth = 1, each packet will be sent as soon as the envelope
# allows. 
#
# when smooth = 0, packets will be sent back to back until the
# envelope does not allow for a full packet, then wait for the
# time required to fill the level back to the maximum number of packets.
# 
# because this generator creates only a sequence of packets of the
# same size, it does not make a periodic difference if the burst size configured
# for a flow is e.g. 2.0 * psize or 2.999 * psize. The only difference it
# makes is that a burst size of e.g.: 2.999 will make the second burst
# of 2 packets send faster after the first burst.

sub gen_packets {
    my($q, $f, $mode) = @_;
    my($psize) = $f->{psize};
    my($rate)  = $f->{rate};
    my($bsize) = $f->{bsize};
    my($fnum)  = $f->{fnum};
    my($pbsize) = int( ($bsize / $psize) / 8) * $psize * 8;

    my($t) = 0;
    my($level) = $bsize;
    my($pnum)  = 0;
    my($p_t) = 0;

    # printf("Flow %03d, psize=%d [byte], rate=%d [bits/sec], burst_size=%d pbsize=%d\n",
    #         $fnum, $psize, $rate, $bsize, $pbsize);

    while($t < $runtime) {
        $pnum++;

        if($mode == 2) {
            # send packets back to back at $linkrate until we have exhausted
            # our bsize, then wait until we have accumulted maximum bsize again
            # and start over.

            # printf("F%03d:P%06.6d: %11d [nsec] level=$level (before)\n", $fnum, $pnum, $t);
    
            my($p);
            $p->{fnum} = $fnum;
            $p->{pnum} = $pnum;
            $p->{psize} = $psize;
            $p->{atime} = $t;
            enqueue($q, $p);

            $level -= ($psize * 8);                         # level after sending this packet
            my($pl) = $psize * 8;
            my($dt) = $p->{psize} * 8 * $nsec / $linkrate;  # time for sending this packet
            my($bl) = $dt * $rate / $nsec;
            my($blevel) = $level + $dt * $rate / $nsec;     # level after we have sent this packet

            # print "pl=$pl, level=$level (after packet), dt=$dt, bl=$bl";
            if($blevel < $psize * 8) {                      # can we immediately send packet after this ?
                # print "End of burst.";
                $t += ($bsize - $level) * $nsec / $rate;
                $level = $bsize;
            } else {
                # print "In burst.";
                $t += $dt;
                $level = $blevel;
            }
        } else {
            if($level < ($psize * 8)) {
                # print("WAIT: level=$level");
                if($mode == 1) {
                    # Smooth:
                    # calculate next $time when we can send next packet
                    $t += ($psize * 8 - $level) * 1000000000 / $rate;
                    $level = $psize * 8;
                } 
                if($mode == 0) {
                    # Max burstyness:
                    # calculate next $time when we can send max burst of packets
                    $t += ($pbsize - $level) * 1000000000 / $rate;
                    $level = $pbsize;
                }
            }

            # printf("F%03d:P%06.6d: %11d [nsec] level=$level (before)\n", $fnum, $pnum, $t);
            $level -= ($psize * 8);
    
            my($p);
            $p->{fnum} = $fnum;
            $p->{pnum} = $pnum;
            $p->{psize} = $psize;
            $p->{atime} = $t;
            $p->{delta} = $p_t ? $t - $p_t : 0;
            $p_t = $t;
            enqueue($q, $p);
        }
    }
}

sub gen_flow {
    my($q, $fnum, $psize, $npackets, $rate, $mode, $quiet) = @_;

    $f->{$fnum}->{fnum}  = $fnum;
    $f->{$fnum}->{psize} = $psize;
    $f->{$fnum}->{rate}  = $rate;
    
    if($mode == 0) {
        # Allow to send packets back to back at infinite link rate
        $f->{$fnum}->{bsize} = $npackets * $psize * 8;
    }
    if($mode == 1) {
        # Allow to send packets only at regular intervals.
        # Minimum burst size

        $f->{$fnum}->{bsize} = $npackets * $psize * 8;
    }

    if($mode == 2) {
        # calculate the minimum bsize required to send npackets back to
        # back at linerate: With above formula of (npackets * psize * 8),
        # will have (psize * 8) level left after sending (npackets - 1),
        # but we will also have accumulated additional level from the
        # time it took to send the prior (npackets -1). Subtracting that
        # accumulated level from bsize will result in the minimum bsize
        # sufficient to send npackets.

        # Is this subtracting too much ? No!
        # Induction proof:
        # - Flow rate is equal to or smaller than linkrate. This means
        #   that the number of bits that our level gains per unit of
        #   time is less than the number of bits of the packet we send
        #   because that packet is sent with linkrate.
        # - When we send 2 packet bursts this means we subtract less than
        #   one packet worth of bits from the burst size, so we will have
        #   enough bits for the first packet. And then according to calculation
        #   enough for the second packet when its send time comes.
        # - When we have a working burst size for N packets, and go to
        #   N+1 packets, we add the bits for one full packet and deduce
        #   less than that, so w will have enough bits when we send the N'th
        #   packet as well. ANd then for N+1 of course also when its time comes.

        $f->{$fnum}->{bsize} = $npackets * $psize * 8;
        $f->{$fnum}->{bsize} -= ($npackets - 1) * 8 * $psize * $rate / $linkrate;
    }

    if(!$quiet) {
        printf "Generate Packets for flow#%d, psize=%d, rate=%d, bsize=%d, mode=%d\n",
           $fnum, $f->{$fnum}->{psize}, $f->{$fnum}->{rate}, $f->{$fnum}->{bsize}, $mode;
    }

    gen_packets($q, $f->{$fnum}, $mode);

    $f->{$fnum}->{level} = $f->{$fnum}->{bsize};
    $f->{$fnum}->{levelt} = 0;
}

# parameters: fnum, psize , npackets (in burst), rate, mode

# generate flow:
# parameters: flow number, packet size, #packets in burst, rate of flow, mode
# mode = 0: packets generated with timing back-to-back for infinite link bandwidth
# mode = 1: packets generated smooth. sending regular packet interval, but can have
#           initial burst
# mode = 2: send burst of packets back to back at link-rate.

# -----
## ==================================================================================
## Pre Test runs
## These tests are searches to find good flow combinations to make a point
## in the actual test runs further below
## ==================================================================================

if(0) {
## ----------------------------------------------------------------------
## Search across all combinations of our 9 flows to see which one is best.
## Maximum burst size on 5 combinations:
## [1(900),2(1000),3(1100)]dequeue Router1 pkts= 3780, maxq= 9000 (of 9000 free 0), latency=0.. 2107785 [nsec], minlevel= -10400 [bits], (packet F1P333)
## [1(900),2(1000),4(930)]dequeue Router1 pkts= 3990, maxq= 8490 (of 8490 free 0), latency=0.. 2016280 [nsec], minlevel= -9760 [bits], (packet F4P90)
## [1(900),2(1000),9(1170)]dequeue Router1 pkts= 3714, maxq= 9210 (of 9210 free 0), latency=0.. 2144352 [nsec], minlevel= -11040 [bits], (packet F1P393)
## [1(900),3(1100),4(930)]dequeue Router1 pkts= 3876, maxq= 8790 (of 8790 free 0), latency=0.. 2096560 [nsec], minlevel= -10560 [bits], (packet F4P450)
## [1(900),3(1100),9(1170)]dequeue Router1 pkts= 3600, maxq= 9510 (of 9510 free 0), latency=0.. 2224704 [nsec], minlevel= -11840 [bits], (packet F1P432)

print "Search 1 Test";
$linkrate = 30000000;
$mode = 0;
@psize = (0, 900, 1000, 1100, 930, 1030, 1130, 970, 1370, 1170);

$quiet = 1;
for($i = 1; $i <= 9; $i++) {
    for($j = $i+1; $j <= 9; $j++) {
        for($k = $j+1; $k <= 9; $k++) {

            undef %{$q1};
            $q1->{name} = "Router1";
            gen_flow($q1, $i, $psize[$i], 3, 10000000, $mode, $quiet);
            gen_flow($q1, $j, $psize[$j], 3, 10000000, $mode, $quiet);
            gen_flow($q1, $k, $psize[$k], 3, 10000000, $mode, $quiet);
            dequeue($q1, $quiet, "[$i($psize[$i]),$j($psize[$j]),$k($psize[$k])]", 0);
        }
    }
}
exit 0;
}

if(0) {
## ------------------------------------------------------------
## Brute force test run to find worst buffer use for Test 2
## (1,2,[3])(4,5,[6])(8,9,[7])dequeue Router4 pkts= 3537, maxq= 11540 (of 9600 BUFFEROVERFLOW free -1940), latency=0.. 2824607 [nsec], minlevel= -14743 [bits], (packet F7P1062)
##

print "Search 2 Test";

$linkrate = 30000000;
$mode = 0;
@psize = (0, 900, 1000, 1100, 930, 1030, 1130, 970, 1370, 1170);
$n = 9;

$nburst = 3;
$quiet = 1;
$trial = 0;
$debug = 1;
for($f1 = 1; $f1 <= $n; $f1++) { $s1 = ":$f1:";
 $debug || print "DEBUG $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
 for($f2 = 1; $f2 <= $n; $f2++) { next if $s1 =~ /:$f2:/; $s2 = "$s1:$f2:";
  $debug || print " DEBUG2 $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
  for($f3 = 1; $f3 <= $n; $f3++) { next if $s2 =~ /:$f3:/; $s3 = "$s2:$f3:";
   $debug || print "  DEBUG3 $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
   $trial || undef %{$q1}; $q1->{name} = "Router1";
   $trial || gen_flow($q1, $f1, $psize[$f1], 3, 10000000, $mode, $quiet);
   $trial || gen_flow($q1, $f2, $psize[$f2], 3, 10000000, $mode, $quiet);
   $trial || gen_flow($q1, $f3, $psize[$f3], 3, 10000000, $mode, $quiet);
   $trial || dequeue($q1, $quiet, "[$f1($psize[$f1]),$f2($psize[$f2]),$f3($psize[$f3])]", 0);

   for($f4 = 1; $f4 <= $n; $f4++) { next if $s3 =~ /:$f4:/; $s4 = "$s3:$f4:";
    $debug || print "   DEBUG4 $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
    for($f5 = 1; $f5 <= $n; $f5++) { next if $s4 =~ /:$f5:/; $s5 = "$s4:$f5:";
     $debug || print "    DEBUG5 $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
     for($f6 = 1; $f6 <= $n; $f6++) { next if $s5 =~ /:$f6:/; $s6 = "$s5:$f6:";
      $debug || print "     DEBUG6 $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
      $trial || undef %{$q2}; $q2->{name} = "Router2";
      $trial || gen_flow($q2, $f4, $psize[$f4], 3, 10000000, $mode, $quiet);
      $trial || gen_flow($q2, $f5, $psize[$f5], 3, 10000000, $mode, $quiet);
      $trial || gen_flow($q2, $f6, $psize[$f6], 3, 10000000, $mode, $quiet);
      $trial || dequeue($q2, $quiet, "[$f4($psize[$f4]),$f5($psize[$f5]),$f6($psize[$f6])]", 0);
 
      for($f7 = 1; $f7 <= $n; $f7++) { next if $s6 =~ /:$f7:/; $s7 = "$s6:$f7:";
       $debug || print "      DEBUG7 $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
       for($f8 = 1; $f8 <= $n; $f8++) { next if $s7 =~ /:$f8:/; $s8 = "$s7:$f8:";
        $debug || print "       DEBUG8 $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
        for($f9 = 1; $f9 <= $n; $f9++) { next if $s8 =~ /:$f9:/; $s9 = "$s8:$f9:";
            $debug || print "        DEBUG9 $f1 $f2 $f3 $f4 $f5 $f6 $f7 $f8 $f9";
            $trial || undef %{$q3}; $q3->{name} = "Router3";
            $trial || gen_flow($q3, $f7, $psize[$f7], 3, 10000000, $mode, $quiet);
            $trial || gen_flow($q3, $f8, $psize[$f8], 3, 10000000, $mode, $quiet);
            $trial || gen_flow($q3, $f9, $psize[$f9], 3, 10000000, $mode, $quiet);
            $trial || dequeue($q3, $quiet, "[$f7($psize[$f7]),$f8($psize[$f8]),$f9($psize[$f9])]", 0);

            printf "Test series for: ($f1,$f2,$f3) ($f4,$f5,$f6) ($f7,$f8,$f9)\n";

            @f=(0,$f1,$f2,$f3,$f4,$f5,$f6,$f7,$f8,$f9);
            print "(0,$f1,$f2,$f3,$f4,$f5,$f6,$f7,$f8,$f9)";

            for($i = 1; $i <= 3; $i++) {
             $t1 = $i == 1 ? "([$f1],$f2,$f3)" : ($i == 2 ? "($f1,[$f2],$f3)" : "($f1,$f2,[$f3])");
             for($j = 4; $j <= 6; $j++) {
              $t2 = $j == 4 ? "([$f4],$f5,$f6)" : ($j == 5 ? "($f4,[$f5],$f6)" : "($f4,$f5,[$f6])");
              for($k = 7; $k <= 9; $k++) {
               $t3 = $k == 7 ? "([$f7],$f8,$f9)" : ($k == 8 ? "($f7,[$f8],$f9)" : "($f7,$f8,[$f9])");

               printf "  Test for $t1 $t2 $t3 -> ($i=%d) ($j=%d) ($k=%d)\n", $f[$i], $f[$j], $f[$k];

               $trial || undef %{$q4}; $q4->{name} = "Router4";
               $trial || send_across_link($q1, $linkrate, $q4, $f[$i]);
               $trial || send_across_link($q2, $linkrate, $q4, $f[$j]);
               $trial || send_across_link($q3, $linkrate, $q4, $f[$k]);
               printf "dequeue [$t1$t2$t3] across %s\n", $q4->{name};
               $trial || dequeue($q4, $quiet, "$t1$t2$t3", 0);
            } } }
} } } } } } } } }
} # if(0)

## ==================================================================================
## Test runs
## ==================================================================================

## Processing in router 1, outgoing interface queue q1:
## Make that queue receive three flows 1, 2, 3
## dequeue the queue

$linkrate = 30000000;
$mode = 0;
@psize = (0, 900, 1000, 1100, 930, 1030, 1130, 970, 1370, 1170);

if(1) {
## ------------------------------------------------------------
## Three flows that happen to create maximum buffer utilization
##

$quiet = 0;
undef %{$q1};
$q1->{name} = "Router1";

print "Test 1: Standard FIFO behavior with rate/burst based flows";
print "----------------------------------------------------------";
print "Observe standard FIFO behavior of 'colliding' rate/burst flows:";
print "  Flows require easily calculated amount of buffer, have easily calculated latency.";
print "  BUT: Flows will violate their envelope condition after being sent from queue";
print;
print "                      Router1                ";
print "                   +-----------+             ";
print "         Flow1 --->|           |             ";
print "         Flow2 --->|       FIFO|------->     ";
print "         Flow3 --->|           |  30 Mbps    ";
print "                   +-----------+             ";
print "         3 x 10 Mbps flows                   ";
print;
print "Starting test:";
printf "Creating three flows, 'send' them into %s\n", $q1->{name};
$nburst = 3;
$i=1;$j=2;$k=3;
gen_flow($q1, $i, $psize[$i], $nburst, 10000000, $mode, $quiet);
gen_flow($q1, $j, $psize[$j], $nburst, 10000000, $mode, $quiet);
gen_flow($q1, $k, $psize[$k], $nburst, 10000000, $mode, $quiet);
print;

print "Check 'arrival' envelope of all packes in queue - they must all be ok:";
$quiet = 1; $atime=1;
verify_queue_envelope($q1, $f, $atime, $quiet);
print;

printf "Sending traffic from %s via FIFO.\n", $q1->{name};
print "Test run starting...";
$quiet=1;
dequeue($q1, $quiet, "", $quiet);
$stime = 0; verify_queue_envelope($q1, $f, $stime, $quiet);
print "Test run done.";
printf "  Observe how packets violate envelope (level < 0) because of delaying of packets in queue\n";
printf "  Observe maximum maxq (queue utilization) is 100%% of max theoretical queue size:\n";
printf "    %d = %d * %d + %d * %d + %d * %d (three flows burst size * packet size)\n",
          $nburst * ( $psize[$i] + $psize[$j] + $psize[$k]),
          $nburst, $psize[$i], $nburst, $psize[$j], $nburst, $psize[$k];
print  "  Observe maximum latency is less than one packet less than serialization time of maxq";
print  "  Observe maximum jitter - min latency = 0 ... max latency across packets (in-time service)";
print;

print "press <RETURN> to continue";
$ignore = <STDIN>;
}

## ------------------------------------------------------------

if(1) {
print "Test 2: The problem: multi-hop latency issue with FIFO";
print "------------------------------------------------------";
print "";
print " Flow1 --->+-----------+ ";
print " Flow2 --->| Rtr1  FIFO|--+";
print " Flow3 --->+-----------+  |";
print " Flow4 --->+-----------+  +L1->+----------+ Flow3,Flow6,Flow7";
print " Flow5 --->| Rtr2  FIFO|---L2->| Rtr4 FIFO|--L4--------------->";
print " Flow6 --->+-----------+  +L3->+----------+ 30 Mbps";
print " Flow8 --->+-----------+  |        |.Lx.|";
print " Flow9 --->| Rtr3  FIFO|--+        v    v";
print " Flow7 --->+-----------+         Do not care";
print "                         30Mbps";
print "";
print "Understand two-hop standard FIFO behavior. In each of Rtr1,Rt2,Rtr3, 3 flows are queued";
print "onto a single output interface, L1,L2,L3. Rtr4 forwards one flow from L1, one flow";
print "from L2 and on flow from L3 onto L4. The other 6 flows are irrelevant, e.g. routed";
print "to some other interface.";

print "press <RETURN> to run the test";
$ignore = <STDIN>;

## (1,2,[3])(4,5,[6])(8,9,[7])dequeue Router4 pkts= 3537, maxq= 11540 (of 9600 BUFFEROVERFLOW free -1940), latency=0.. 2824607 [nsec], minlevel= -14743 [bits], (packet F7P1062)

print "Starting test:";
@psize = (0, 900, 1000, 1100, 930, 1030, 1130, 970, 1370, 1170);
$nburst = 3;

$quiet = 0;

undef %{$q1}; $q1->{name} = "Router1"; $i=1;$j=2;$k=3;
printf "Creating three flows for %s and queuing them onto L1\n", $q1->{name};
$quiet=0;
gen_flow($q1, $i, $psize[$i], $nburst, 10000000, $mode, $quiet);
gen_flow($q1, $j, $psize[$j], $nburst, 10000000, $mode, $quiet);
gen_flow($q1, $k, $psize[$k], $nburst, 10000000, $mode, $quiet);
$atime=1;
print;
print "The arrival time of all three flows are now all compliant wih their envelope. Checking it:";
verify_queue_envelope($q1, $f, $atime, $quiet);
print;
print "Dequeuing packets from Router 1:";
$quiet=1; dequeue($q1, $quiet, "[$i($psize[$i]),$j($psize[$j]),$k($psize[$k])]", 0);
$stime=0;
verify_queue_envelope($q1, $f, $stime, $quiet);
print;
print "Processing packets for Router2, Router3";
undef %{$q2}; $q2->{name} = "Router2"; $i=4;$j=5;$k=6;
printf "Creating three flows for %s and queuing them onto L2\n", $q2->{name};
$quiet=0;
gen_flow($q2, $i, $psize[$i], $nburst, 10000000, $mode, $quiet);
gen_flow($q2, $j, $psize[$j], $nburst, 10000000, $mode, $quiet);
gen_flow($q2, $k, $psize[$k], $nburst, 10000000, $mode, $quiet);
$quiet=1; dequeue($q2, $quiet, "[$i($psize[$i]),$j($psize[$j]),$k($psize[$k])]", 0);

undef %{$q3}; $q3->{name} = "Router3"; $i=8;$j=9;$k=7;
printf "Creating three flows for %s and queuing them onto L3\n", $q3->{name};
$quiet=0;
gen_flow($q3, $i, $psize[$i], $nburst, 10000000, $mode, $quiet);
gen_flow($q3, $j, $psize[$j], $nburst, 10000000, $mode, $quiet);
gen_flow($q3, $k, $psize[$k], $nburst, 10000000, $mode, $quiet);
$quiet=1; dequeue($q3, $quiet, "[$i($psize[$i]),$j($psize[$j]),$k($psize[$k])]", 0);

print;
undef %{$q4}; $q4->{name} = "Router4"; $i=3; $j=6; $k=7;
printf "Passing flow $i,$j,$k onto FIFO for L4 in %s\n", $q4->{name};
send_across_link($q1, $linkrate, $q4, 3);
send_across_link($q2, $linkrate, $q4, 6);
send_across_link($q3, $linkrate, $q4, 7);
verify_queue_envelope($q4, $f, $atime, $quiet);
printf "dequeue ($i,$j,$k) across %s L4\n", $q4->{name};
dequeue($q4, $quiet, "($i,$j,$k)", 0);
print;
print "Test run finished. Observe results:";
print "- Observe how the maximum buffer size required for the L4 FIFO is larger than the";
print "  calculated max (buffer size of the three flows sent into it). This is because when";
print "  the flows arrived via L1,L2,L3, they already did not comply with their envelope.";
print "- Accordingly, the maximum latency (2.82 [msec]) is longer the assumed theretical";
print "  maximum for the buffer size: 2.56 [msec] = 8*3*(1100+1130+970)*1000/30000000.";
print "- This ultimately is the problem UBS, LSDN and gLBF are solving to ensure per-hop";
print "  bounded latency: predictable and non-hard calculated. ";
print;
print "press <RETURN> to continue";
$ignore = <STDIN>;
}

## ------------------------------------------------------------

if(1) {
print "Test 3: Explaining gLBF                                   ";
print "-----------------------                                   ";
print "                                                          ";
print "               Router 1               Router 4            ";
print "         +-----------------+     +---------------+        "; 
print " Flow1 ->|                 |     |               |        ";
print " Flow2 ->|. X1 FIFO        |-L1->|(shape) X2 FIFO|--L4--->";
print " Flow3 ->+-----------------+     +---------------+ 30 Mbps";
print "            |---------------------------->|               ";
print "                hop latency                               ";
print "";
print "(X2 - X1) is the hop latency. The variable part of it is the time";
print "of the packet through the FIFO in router 1. Two packets P1 and P2";
print "of the same flow may be coalesced if P1 is delayed by the queue, but";
print "P2 later on is not. When the coalesed packets then reach Router 4";
print "FIFO, their burst size can be larger than expected, leading to larger";
print "delay through that FIFO. UBS solves this problem of inserting a per-flow";
print "(shape) stage before reaching X2, therefore creating easily calculated";
print "determinstic latency in router 4 FIFO.";
print;
print "               Router 1               Router 4            ";
print "         +-----------------+     +--------------+         "; 
print " Flow1 ->|          gLBFF  |     |gLBF          |         ";
print " Flow2 ->|. X1 FIFO measure|-L1->|delay  X2 FIFO|--L4---->";
print " Flow3 ->+-----------------+     +--------------+ 30 Mbps ";
print "            |---------------------------->|               ";
print "                hop latency                               ";
print "";
print "gLBF re-establishes the required inter-packet spacing at X2 by";
print "delaying all packets exactly so that their hop latency is equal.";
print "Their inter-packet spacing will this be exactly as in point X1.";
print "This is done by knowing the maximum possibly neded size and";
print "therefore time through router 1 FIFO and L1, subtracting the measured";
print "actual time for the packet from those maximum, signaling that time to";
print "router 4, and then delaying the packet by that value in router 4";
print "before reaching X2.";
print;
print "press <RETURN> to run the test";
$ignore = <STDIN>;

print "Starting test Test 3:";
@psize = (0, 900, 1000, 1100, 930, 1030, 1130, 970, 1370, 1170);
$nburst = 3;

print "Test 3.1 without gLBF: Creating flows 1,2,3 Rtr1";

$quiet=0; undef %{$q1}; $q1->{name} = "Router1"; $i=1;$j=2;$k=3;
gen_flow($q1, $i, $psize[$i], $nburst, 10000000, $mode, $quiet);
gen_flow($q1, $j, $psize[$j], $nburst, 10000000, $mode, $quiet);
gen_flow($q1, $k, $psize[$k], $nburst, 10000000, $mode, $quiet);
# print_queue($q1);
$quiet=1; dequeue($q1, $quiet, "[$i($psize[$i]),$j($psize[$j]),$k($psize[$k])]", 0);
# $stime = 0;
# verify_queue_envelope($q1, $f, $stime, $quiet);

$quiet=0; undef %{$q4}; $q4->{name} = "Router4";
send_across_link($q1, $linkrate, $q4, 3);
send_across_link($q1, $linkrate, $q4, 2);
send_across_link($q1, $linkrate, $q4, 1);
$quiet = 1; $atime = 1;
verify_queue_envelope($q4, $f, $atime, $quiet);
print "Test finished.";
print;
print "Observe that the latency is 'in-time': It can be all the way from '0'";
print "on the sender, when there is no queuing in Rtr1 FIFO, up to 2,1 msec,";
print "close to the maximum buffer size (2,4 msec). After arrival on Rtr4,";
print "The latency will vary from the link serialization time for the shortest";
print "packet (240 usec = 900 bytes) to the max latency on Rtr1 plus the serialization";
print "time of the longest packet (1100 bytes).";
print;
print "press <RETURN> to run the test";
$ignore = <STDIN>;

print "Test 3.2 WITH gLBF: Creating flows 1,2,3 Rtr1";
print "...skipping steps we already showed in the previous step.";

undef %{$q4lbf}; $q4lbf->{name} = "Router4 X2";
$quiet = 1; glbf_delay($q4, $q4lbf, $quiet);
verify_queue_envelope($q4lbf, $f, $atime, $quiet);
print "Test finished.";
print;
print "Observe the on-time behavior after gLBF delay: all packets have the same latency";
print "At point X2. There are also no level errors. Exept for the additional latency,";
print "the timing of the packets is as it was at X1.";

print "press <RETURN> to continue";
$ignore = <STDIN>;
}

# ===========================================================================================

if(1) {
print "Test 4: Solving the problem with glBF:";
print "--------------------------------------";
print "";
print " Flow1 ->+--------------+ ";
print " Flow2 ->|Rtr1  FIFOgLBF|-+";
print " Flow3 ->+--------------+ |";
print " Flow4 ->+--------------+ +L1->+-------------------+ Flow3,Flow6,Flow7";
print " Flow5 ->|Rtr2  FIFOgLBF|--L2->|gLBFdelay Rtr4 FIFO|--L4------------->";
print " Flow6 ->+--------------+ +L3->+-------------------+ 30 Mbps";
print " Flow8 ->+--------------+ |                |.Lx.|";
print " Flow9 ->|Rtr3  FIFOgLBF|-+                v    v";
print " Flow7 ->+--------------+                 Do not care";
print "                          30Mbps";
print "";
print "Repeat Test 2 setup except that we now add gLBF into Rtr1,Rt2,Rtr3,Rtr4:";
print "On Rt1,Rtr2,Rtr3 we insert into each packet the target delay that the packet";
print "should experience in the gLBFdelay stage on Rtr4. This delay is calculated";
print "before sending the packet onto L1,L2,L3: maximum possible time for a packet in the FIFO";
print "(max latency) minus the measured time the packet actually spent in the FIFO";

print "press <RETURN> to run the test";
$ignore = <STDIN>;

print "Starting test:";
@psize = (0, 900, 1000, 1100, 930, 1030, 1130, 970, 1370, 1170);
$nburst = 3;

print "(unchanged from Test 2) Creating 9 flows and passing them through Rtr1,Rtr2,Rt3";

$quiet=0; undef %{$q1}; $q1->{name} = "Router1"; $i=1;$j=2;$k=3;
gen_flow($q1, $i, $psize[$i], $nburst, 10000000, $mode, $quiet);
gen_flow($q1, $j, $psize[$j], $nburst, 10000000, $mode, $quiet);
gen_flow($q1, $k, $psize[$k], $nburst, 10000000, $mode, $quiet);
# print_queue($q1);
$quiet=1; dequeue($q1, $quiet, "[$i($psize[$i]),$j($psize[$j]),$k($psize[$k])]", 0);

$quiet=0; undef %{$q2}; $q2->{name} = "Router2"; $i=4;$j=5;$k=6;
gen_flow($q2, $i, $psize[$i], $nburst, 10000000, $mode, $quiet);
gen_flow($q2, $j, $psize[$j], $nburst, 10000000, $mode, $quiet);
gen_flow($q2, $k, $psize[$k], $nburst, 10000000, $mode, $quiet);
$quiet=1; dequeue($q2, $quiet, "[$i($psize[$i]),$j($psize[$j]),$k($psize[$k])]", 0);

$quiet=0; undef %{$q3}; $q3->{name} = "Router3"; $i=8;$j=9;$k=7;
gen_flow($q3, $i, $psize[$i], $nburst, 10000000, $mode, $quiet);
gen_flow($q3, $j, $psize[$j], $nburst, 10000000, $mode, $quiet);
gen_flow($q3, $k, $psize[$k], $nburst, 10000000, $mode, $quiet);
$quiet=1; dequeue($q3, $quiet, "[$i($psize[$i]),$j($psize[$j]),$k($psize[$k])]", 0);

$stime = 0;
verify_queue_envelope($q1, $f, $stime, $quiet);
verify_queue_envelope($q2, $f, $stime, $quiet);
verify_queue_envelope($q3, $f, $stime, $quiet);

print;
undef %{$q4}; $q4->{name} = "Router4"; $i=3, $j=6, $k=7;
printf "Passing flow $i,$j,$k towards '%s'\n", $q4->{name};
send_across_link($q1, $linkrate, $q4, $i);
send_across_link($q2, $linkrate, $q4, $j);
send_across_link($q3, $linkrate, $q4, $k);
# print_queue($q4);

print;
print "Checking the flow envelope of packets arriving into Router 4";
print "This will show the level errors we know from Test 2.";
$quiet=1; $atime = 1; verify_queue_envelope($q4, $f, $atime, $quiet);

print;
undef %{$q4lbf}; $q4lbf->{name} = "Rtr4 X2";
$quiet = 1; glbf_delay($q4, $q4lbf, $quiet);
verify_queue_envelope($q4lbf, $f, $atime, $quiet);
print;

printf "dequeue ($i,$j,$k) across %s\n", $q4lbf->{name};
# $quiet=1; dequeue($q4lbf, $quiet, "($i,$j,$k)", 0);
$quiet=0; dequeue($q4lbf, $quiet, "($i,$j,$k)", $q4);

print;
print "Compare with dequeuing times without gLBF delay (e.g.: as in Test 2)";
printf "dequeue ($i,$j,$k) across %s\n", $q4->{name};
$quiet = 1; dequeue($q4, $quiet, "($i,$j,$k)", 0);
print;
print "Test 4 run finished.";
print;

print "- Observe how after gLBF delay, the latency is not fixed, but a range. This is because";
print "  all packets from L1 will have one latency (2693334 as from Test 3), but all packets";
print "  from L2 will have another latency, because the buffer size in Rtr2 is different,";
print "  because it was calculated from the three flows different packet sizes. Likewise ";
print "  packets from Rtr3/L3.";
print "- Observe how dequeuing after gLBF delay X2 does resolve he buffer overflows and";
print "  unexpected increase in latency as observed in Test 2.";

print "press <RETURN> to continue";
$ignore = <STDIN>;
}

exit 0;

