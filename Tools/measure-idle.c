#include <libproc.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv){
 if(argc != 3){fprintf(stderr,"Usage: %s PID SECONDS\n",argv[0]);return 2;}
 int pid=atoi(argv[1]),seconds=atoi(argv[2]);
 if(pid <= 0 || seconds < 1 || seconds > 300){fprintf(stderr,"Expected a positive PID and 1–300 seconds.\n");return 2;}
 struct rusage_info_v4 before={0},after={0};
 if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t *)&before)){perror("before");return 1;}
 struct timespec start,end;clock_gettime(CLOCK_MONOTONIC,&start);sleep(seconds);clock_gettime(CLOCK_MONOTONIC,&end);
 if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t *)&after)){perror("after");return 1;}
 double wall=(end.tv_sec-start.tv_sec)+(end.tv_nsec-start.tv_nsec)/1e9;
 double user=(after.ri_user_time-before.ri_user_time)/1e9,sys=(after.ri_system_time-before.ri_system_time)/1e9;
 printf("{\"pid\":%d,\"seconds\":%.3f,\"cpu_seconds\":%.6f,\"cpu_percent_one_core\":%.4f,\"interrupt_wakeups\":%llu,\"package_idle_wakeups\":%llu,\"footprint_mib_start\":%.2f,\"footprint_mib_end\":%.2f,\"disk_read_bytes\":%llu,\"disk_write_bytes\":%llu}\n",pid,wall,user+sys,(user+sys)/wall*100,after.ri_interrupt_wkups-before.ri_interrupt_wkups,after.ri_pkg_idle_wkups-before.ri_pkg_idle_wkups,before.ri_phys_footprint/1048576.0,after.ri_phys_footprint/1048576.0,after.ri_diskio_bytesread-before.ri_diskio_bytesread,after.ri_diskio_byteswritten-before.ri_diskio_byteswritten);
 return 0;
}
