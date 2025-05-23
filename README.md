# trade-tariff-tools

This repo is used as a wastebasket for general workflows and scripts that the tariff team need as part of our release and other processes.

### bin/fetch-commodities

In order to run this script you will need the [requests library](https://pypi.org/project/requests/) and a relatively recent version of python (I'm on 3.11.4)

I installed requests by running:

```shell
pip install requests
```

Update the commodities.txt file with your commodities

And run the script with:

```shell
./fetch-commodities
```

In VScode for windows you should be able to right click the python file and hit run

This should print a markdown table you can copy into your Stop Press Notice

For example, this will produce:

| Commodity Code | Description |
| -------------- | ----------- |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/3824999214" target="_blank">3824999214</a> | Other |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1516209831" target="_blank">1516209831</a> | Consigned from the United Kingdom |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1516209822" target="_blank">1516209822</a> | Consigned from the United Kingdom |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1516209823" target="_blank">1516209823</a> | Consigned from China |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1516209832" target="_blank">1516209832</a> | Consigned from China |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1518009122" target="_blank">1518009122</a> | Consigned from the United Kingdom |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1518009123" target="_blank">1518009123</a> | Consigned from China |
| <a href="https://www.trade-tariff.service.gov.uk/commodities/1518009131" target="_blank">1518009131</a> | Consigned from the United Kingdom |

### bin/ecsexec.sh

Script to get an ECS Exec shell up on the AWS environment you are currently in. By default it will start a `rails console`

Its intended copied to the AWS Console where there are limited shell tools but will probably work fine locally with AWS Session Manager

```shell
ecsexec.sh <service> [<command>]
```

eg, to get a rails console for the XI service

```shell
ecsexec.sh xi
```

eg, to start a bash shell for the UK service

```shell
ecsexec.sh uk sh
```

eg, to run a rake task for XI

```shell
ecsexec.sh xi "bundle exec rake tariff:jobs"
```
