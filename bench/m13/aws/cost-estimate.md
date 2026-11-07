# Tokyo benchmark cost estimate

Prepared 2026-11-04 for Linux On-Demand shared-tenancy EC2 in `ap-northeast-1`.
This is a public list-price estimate, not an account bill or an AWS resource plan.
No discounts, credits, tax, or currency conversion are assumed.

| Item | Quantity | Unit price (USD) | Subtotal |
|---|---:|---:|---:|
| c7i.2xlarge server | 1 | 0.4494/hour | 0.4494/hour |
| c7i.4xlarge generator | 1 | 0.8988/hour | 0.8988/hour |
| Public IPv4 | 2 | 0.005/hour | 0.0100/hour |
| gp3 baseline storage | 80 GiB total | 0.096/GiB-month | 7.68/month while retained |

Compute and IPv4 total **USD 1.3582/hour**. With storage prorated over an
illustrative 30-day month, a four-hour run followed by destruction is approximately
**USD 5.48**. Provisioning/build time counts as running time; the default stop timer
includes it. Actual EBS billing follows AWS's proration rules.

The estimate excludes internet data transfer out, retained snapshots, and any
optional services added later. Same-AZ benchmark traffic uses private IPs;
no cross-AZ traffic, NAT Gateway, or load balancer is planned. Downloading tools
and collecting results can have separate transfer implications.

Stopping the instances ends compute billing, but the **80 GiB of EBS remains**
until deletion. Auto-assigned public IPs are released on stop; no Elastic IPs
are allocated by this module. Verify resource deletion after `terraform destroy`.

## Sources and refresh

- [AWS public EC2 Tokyo Linux price data](https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/Asia%20Pacific%20%28Tokyo%29/Linux/index.json), retrieved 2026-11-04. Selected records are in `public-prices.json`.
- [EC2 On-Demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/).
- [VPC public IPv4 pricing](https://aws.amazon.com/vpc/pricing/).
- [AWS EBS Tokyo pricing reference](https://pages.awscloud.com/rs/112-TZM-766/images/AWS-Black-Belt_2024_Amazon-Elastic-Block-Store-Basic_1209_v1.pdf) gives gp3 at USD 0.096/GiB-month. The USD 0.096 rate was also confirmed with the AWS Pricing API on 2026-11-04 (AmazonEC2, regionCode=ap-northeast-1, volumeApiName=gp3, productFamily=Storage). Reconfirm it on the [EBS pricing page](https://aws.amazon.com/ebs/pricing/) before applying.

Recheck current public prices and the actual resource plan immediately before
provisioning. Keep account identity, quota, AMI, AZ-offering checks, and the actual plan in a
private experiment record. A successful plan does not prove launch permissions
or current EC2 capacity.
