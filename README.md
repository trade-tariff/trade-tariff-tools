# trade-tariff-tools

This repo is used as a wastebasket for general workflows and scripts that the tariff team need as part of our release and other processes

### bin/fetch-commodities

In order to run this script you will need the [requests library](https://pypi.org/project/requests/) and a relatively recent version of python (I'm on 3.11.4)

I installed requests by running:

```shell
pip install requests
```

And run the script with:

```shell
./fetch-commodities test-commodities.txt
```

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
