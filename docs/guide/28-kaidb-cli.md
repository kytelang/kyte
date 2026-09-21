# 28. The kaidb CLI

`kaidb-cli` is a small command line client for a running kaidb server. It owns no
storage of its own: it connects over the binary protocol, sends your SQL, and prints
the results as a MySQL style ASCII table. It is the quickest way to poke at a
database, run a one off query, or feed a script of statements.

## Usage

```sh
kaidb-cli [host[:port]] [--tls|--no-tls] [-u user] [-p pass] [-d db] [-c "SQL"]
```

The options are:

- `host` or `host:port` : a bare positional argument giving the server to connect to.
- `--tls` / `--no-tls` : force TLS on or off for the connection.
- `-u user` : the user to authenticate as.
- `-p pass` : the password.
- `-d db` : the database to use.
- `-c "SQL"` : run one statement and exit.

When you do not pass them, the host, port, and TLS setting come from the `db.json`
file, and the authentication defaults to the seeded `admin` user with password
`admin` against the `default` database. Set your own values in production.

## The three modes

`kaidb-cli` works in whichever of three modes matches how you invoke it.

### One shot

Pass `-c` with a single statement. The client connects, runs it, prints the result,
and exits. This is the mode you reach for in scripts and health checks.

```sh
kaidb-cli 127.0.0.1:3009 -u admin -p admin -d shop -c "SELECT COUNT(*) FROM ord"
```

### Piped script

Pipe a file of statements on standard input. The client splits the input on `;` and
runs each statement in turn.

```sh
kaidb-cli 127.0.0.1:3009 -d shop < schema.sql
```

### Interactive

Run it against a TTY with no `-c` and no piped input, and you get an interactive
prompt. Type statements at the `kaidb> ` prompt, and leave with `exit`, `quit`, or
Ctrl and D.

```sh
kaidb-cli 127.0.0.1:3009 -u admin -p admin -d shop
```

```
kaidb CLI (binary protocol)
kaidb> SELECT id, customer FROM ord WHERE status = 'paid';
+----+----------+
| id | customer |
+----+----------+
|  2 | Ravi     |
+----+----------+
1 row(s) in set
kaidb> exit
```

## Reading the output

- A `SELECT` prints an ASCII table of the rows, followed by a line such as
  `1 row(s) in set`.
- A statement that changes data (`INSERT`, `UPDATE`, `DELETE`) prints
  `Query OK, N row(s) affected`.
