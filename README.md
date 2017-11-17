## mha_switch

swith MySQL replication with custom scripts by use [MHA](https://github.com/yoshinorim/mha4mysql-manager)

#### all dependecy Perl modules are the same with `MHA`, and all of the scripts are based on `MHA 0.56` version.

## Instruction

the full code structure:
```
mha_switch
├── bin
│   ├── init_conf_loads
│   ├── master_ip_failover
│   └── master_ip_online_change
├── log
│   └── switch.log
├── masterha
│   ├── app_56.conf
│   ├── app_default.cnf
│   ├── masterha-script.cnf
│   └── masterha-script.pm
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

### configure file

1. `app_56.conf` is one MySQL replication instances.

2. `masterha-script.cnf` is the MySQL replication info which refers to `app_56.conf`, you can specify multigroup if you have multiple MySQL replications. the `proxysql` is optional option, you can set multiple proxysqls(master/backup) which split by comma symbol.

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
         |    | master | 10.0.21.17:3308  | slave | 10.0.21.7:3308  |
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
