# LPAR test harness (`lpar-tests/`)

Automated **MQ** (`run_mq_all.sh`), **true legacy** (`run_legacy_all.sh`),
**MQ forced to RX=1** (`run_rx_1_all.sh`), and **MQ then legacy**
(`run_all.sh`) suites for PowerVM **ibmveth**.

**Start here**

| Doc | Contents |
|-----|----------|
| [../README.md](../README.md) | Lab roles, two-LPAR iperf, `lab.conf`, portable LPARs |
| [SUITE-HELP.txt](SUITE-HELP.txt) | Every knob, phases, examples |
| [lab.conf.example](lab.conf.example) | Copy to `lab.conf` (gitignored) and edit |
| [../TEST-PLAN.txt](../TEST-PLAN.txt) | Test IDs T1–T29 and pass criteria |

**Quick setup (any LPAR)**

```bash
cd lpar-tests
cp lab.conf.example lab.conf
# Edit IFACE, PEER, DUT_IP, IBMVETH_KO, optional KERNEL_SRC / LEGACY

sudo ./preflight.sh
sudo ./run_mq_all.sh                  # MQ only
sudo ./run_all.sh                     # MQ + LEGACY adapters from lab.conf
```

`KERNEL_SRC` is optional: used only for **t24** (netdev qstats ABI). Set
it in `lab.conf` or rely on auto-detect (`/lib/modules/$(uname -r)/source`,
`/root/ming/linux`, etc. — see `find_kernel_src` in `env.sh`).