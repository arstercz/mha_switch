## mha_switch

Switch MySQL replication with custom scripts by use [MHA](https://github.com/yoshinorim/mha4mysql-manager), read more from [blog](https://arstercz.com/mha_switch-%E7%BB%93%E5%90%88-proxysql-%E5%92%8C-mha-%E5%88%87%E6%8D%A2-mysql-%E4%B8%BB%E4%BB%8E/).

*note:* 

- all dependecy Perl modules are the same with `MHA`, and all of the scripts are based on `MHA 0.56` version.
- the `event_scheduler` feature can be used in `MHA 0.58` version, otherwise you must give a big enough value to the `--running_updates_limit` and `--running_seconds_limit` option. read more from [pull-44](https://github.com/yoshinorim/mha4mysql-manager/pull/44) and you can apply this patch into your low version `MHA`.


## Introduction

the full code structure:
```
mha_switch
├── bin
│   ├── init_conf_loads
│   ├── master_ip_failover
│   └── master_ip_online_change
├── LICENSE
├── log
│   └── switch.log
├── masterha
│   ├── app_56.conf
│   ├── app_default.cnf
│   ├── masterha-script.cnf
│   ├── masterha-script.pm
│   └── mha_sudoer
└── README.md

```

### scripts

1. the `master_ip_failover` and `master_ip_online_change` are refer to `mha4mysql-manager/samples/scripts/`. these path should be the same as the option values in the global default file `app_default.cnf`. 

2. `init_conf_loads` contains the MySQl `root user`  password which in `base64` format.

3. `masterha-script.pm` is our custum module that support the following features:
```
parse masterha-script.cnf file
virtual ip switch,
block/release mysql user
proxysql switch
```
read more from [proxysql](https://github.com/sysown/proxysql).

4. `mha_sudoer` should be copy to all of the MySQL Host's `/etc/sudoers.d`, so that `mha_switch` can switch virtual ip address with normal user(default is `mha` user). 

### configure file

1. `app_56.conf` is one MySQL replication instances.

2. `masterha-script.cnf` is the MySQL replication info which refers to `app_56.conf`, you can specify multigroup if you have multiple MySQL replications. the `proxysql` is optional option, you can set multiple proxysqls(master/backup) which split by comma symbol. eg:
```
# vip and proxysql are optional option, you can ignore if you do not use vip or proxysql
10.0.21.7:3308 10.0.21.17:3308
   vip 10.0.21.97
   block_user ^percona$|^proxysqlmon$
   block_host ^10\.0\.21\.%$
   proxysql admin2:admin2@10.0.21.5:6032:w1:r2,admin2:admin2@10.0.21.7:6032:w1:r2
```
the `10.0.21.7:3308 10.0.21.17:3308` is the master, slave ip address and port, you must specify multi `ip:port` if you have many slaves; `vip 10.0.21.97` means that master services to application by the virtual ip address, MHA will switch the vip address when you use MHA switch the replication, this means the application will do nothing to connect new master only when it has the retry mechanism, `vip` is optional option, you can ignore this if you do not use vip address; `block_user` and `block_host` means MHA will block the user which in old master instance, read more from [blocking-user-accounts](http://code.openark.org/blog/mysql/blocking-user-accounts); the last line `proxysql` option is optional, you can setup if you use proxysql, the value means there are two proxysqls, include the following proxysql administration info:
```
proxysql1:
  username:    admin2
  password:    admin2
  ip:          10.0.21.5
  port:        6032        # admin port
  write group: 1           # begin with w
  read group:  2           # begin with r

proxysql2:
  username:    admin2
  password:    admin2
  ip:          10.0.21.7
  port:        6032        # admin port
  write group: 1           # begin with w
  read group:  2           # begin with r
```

## How to use

the `master_ip_failover` and `master_ip_online_change` refer the path `/etc/masterha/masterha-script.pm` and `/etc/masterha/masterha-script.cnf` by default, if your `masterha` dirs not in `/etc`, then  you should change the value in the two scripts.

### structure

if we have the following structure:
```
              +------------+            +------------+
              | proxysql 1 | 10.0.21.5  | proxysql 2 | 10.0.21.7
              +------------+            +------------+
                    |                         | 
                    |                         |
                    |                         |
                    |                         |
         +----------+-------------------------+----------------------+
         |                                                           |
         |    +--------+                  +-------+                  |
         |    | master | 10.0.21.17:3308  | slave | 10.0.21.7:3308   |
         |    +--------+                  +-------+                  |
         |                                                           |
         +-----------------------------------------------------------+

```

### proxysql mysql servers

before `mha` the proxysql `runtime_mysql_servers` is:
```
+--------------+------------+------+--------+--------+-------------+-----------------+---------------------+---------+----------------+---------+
| hostgroup_id | hostname   | port | status | weight | compression | max_connections | max_replication_lag | use_ssl | max_latency_ms | comment |
+--------------+------------+------+--------+--------+-------------+-----------------+---------------------+---------+----------------+---------+
| 1            | 10.0.21.17 | 3308 | ONLINE | 1000   | 0           | 2000            | 0                   | 0       | 0              |         |
| 2            | 10.0.21.17 | 3308 | ONLINE | 1000   | 0           | 2000            | 0                   | 0       | 0              |         |
| 2            | 10.0.21.7  | 3308 | ONLINE | 1000   | 0           | 2000            | 30                  | 0       | 0              |         |
+--------------+------------+------+--------+--------+-------------+-----------------+---------------------+---------+----------------+---------+
```

Execute the following command to switch MySQL recplication and change the proxysql setting:
```
# masterha_master_switch --master_state=alive --global_conf=/etc/masterha/app_default.cnf --conf=/etc/masterha/app_56.conf --orig_master_is_new_slave
...
...
Thu Nov 16 15:52:00 2017.490641 delete proxysql repl group on 10.0.21.5:6032 ok!
Thu Nov 16 15:52:00 2017.497134 set read_only on proxysql 10.0.21.5:6032 ok!
...
...
Thu Nov 16 15:52:06 2017.306978 Delete old proxysql write group 10.0.21.17:3308 with group 1 ok!
Thu Nov 16 15:52:06 2017.307767 Insert new proxysql write group 10.0.21.7:3308 with group 1 ok!
Thu Nov 16 15:52:06 2017.308202 Insert new proxysql read group 10.0.21.7:3308 with group 2 ok!
Thu Nov 16 15:52:06 2017.312171 Insert orig master as new proxysql read group 10.0.21.17:3308 with group 2 ok!
Thu Nov 16 15:52:06 2017.312908 insert proxysql repl group on 10.0.21.5:6032 ok!
Thu Nov 16 15:52:06 2017.321330 proxysql load server to runtime ok!
Thu Nov 16 15:52:06 2017.348377 proxysql save server to disk ok!
Thu Nov 16 15:52:06 2017.352720 set proxysql 10.0.21.7:6032 readwrite ok!
```
you can read the `log/switch.log` to get more message.

### proxysql mysql servers

after `mha` the proxysql `runtime_mysql_servers` is:
```
+--------------+------------+------+--------+--------+-------------+-----------------+---------------------+---------+----------------+---------+
| hostgroup_id | hostname   | port | status | weight | compression | max_connections | max_replication_lag | use_ssl | max_latency_ms | comment |
+--------------+------------+------+--------+--------+-------------+-----------------+---------------------+---------+----------------+---------+
| 1            | 10.0.21.7  | 3308 | ONLINE | 1000   | 0           | 2000            | 0                   | 0       | 0              |         |
| 2            | 10.0.21.7  | 3308 | ONLINE | 1000   | 0           | 2000            | 0                   | 0       | 0              |         |
| 2            | 10.0.21.17 | 3308 | ONLINE | 1000   | 0           | 2000            | 30                  | 0       | 0              |         |
+--------------+------------+------+--------+--------+-------------+-----------------+---------------------+---------+----------------+---------+
```

there is no `10.0.21.17` entries if no `--orig_master_is_new_slave` option in MHA execute.

## License

MIT / BSD
