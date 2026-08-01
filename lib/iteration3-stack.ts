// Amazon Elastic Kubernetes Service (Amazon EKS) cluster provisioned with AWS Cloud Development Kit (AWS CDK)
import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as iam from 'aws-cdk-lib/aws-iam';
import { KubectlV30Layer } from '@aws-cdk/lambda-layer-kubectl-v30';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export interface EksUpgradePocStackProps extends cdk.StackProps {
  /**
   * Optional suffix appended to named resources so multiple deployments
   * can coexist in the same account/region. Must match /^[a-z0-9-]{1,20}$/.
   */
  readonly nameSuffix?: string;
}

export class EksUpgradePocStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: EksUpgradePocStackProps = {}) {
    super(scope, id, props);

    const suffix = props.nameSuffix ? `-${props.nameSuffix}` : '';
    const clusterName = `eks-upgrade-poc${suffix}`;

    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2,
      natGateways: 1,
      // VPC flow logs to CloudWatch for network troubleshooting and audit
      // (satisfies cdk-nag AwsSolutions-VPC7).
      flowLogs: {
        CloudWatch: {
          trafficType: ec2.FlowLogTrafficType.ALL,
        },
      },
    });

    const cluster = new eks.Cluster(this, 'Cluster', {
      clusterName,
      version: eks.KubernetesVersion.V1_30,
      kubectlLayer: new KubectlV30Layer(this, 'KubectlLayer'),
      vpc,
      defaultCapacity: 0,
      endpointAccess: eks.EndpointAccess.PUBLIC_AND_PRIVATE,
      // Publish all control-plane log types to CloudWatch for audit and
      // diagnostics (satisfies cdk-nag AwsSolutions-EKS2).
      clusterLogging: [
        eks.ClusterLoggingTypes.API,
        eks.ClusterLoggingTypes.AUDIT,
        eks.ClusterLoggingTypes.AUTHENTICATOR,
        eks.ClusterLoggingTypes.CONTROLLER_MANAGER,
        eks.ClusterLoggingTypes.SCHEDULER,
      ],
    });

    cluster.addNodegroupCapacity('Nodes', {
      nodegroupName: `poc-nodes${suffix}`,
      instanceTypes: [new ec2.InstanceType('t3.medium')],
      minSize: 2,
      maxSize: 3,
      desiredSize: 2,
      amiType: eks.NodegroupAmiType.AL2_X86_64,
    });

    new eks.CfnAddon(this, 'VpcCni', {
      clusterName: cluster.clusterName,
      addonName: 'vpc-cni',
      addonVersion: 'v1.21.1-eksbuild.7',
      resolveConflicts: 'OVERWRITE',
    });

    new eks.CfnAddon(this, 'KubeProxy', {
      clusterName: cluster.clusterName,
      addonName: 'kube-proxy',
      addonVersion: 'v1.30.14-eksbuild.30',
      resolveConflicts: 'OVERWRITE',
    });

    new eks.CfnAddon(this, 'CoreDns', {
      clusterName: cluster.clusterName,
      addonName: 'coredns',
      addonVersion: 'v1.11.4-eksbuild.33',
      resolveConflicts: 'OVERWRITE',
    });

    new cdk.CfnOutput(this, 'ClusterName', { value: cluster.clusterName });
    new cdk.CfnOutput(this, 'ClusterArn', { value: cluster.clusterArn });

    // --- AWS Load Balancer Controller (Helm) ---

    const lbcSa = cluster.addServiceAccount('AwsLoadBalancerController', {
      name: 'aws-load-balancer-controller',
      namespace: 'kube-system',
    });

    // Read-only discovery actions — cannot be scoped to specific ARNs because
    // the controller discovers resources dynamically at runtime.
    lbcSa.role.addToPrincipalPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'elasticloadbalancing:Describe*',
        'ec2:DescribeAvailabilityZones',
        'ec2:DescribeInternetGateways',
        'ec2:DescribeVpcs',
        'ec2:DescribeSubnets',
        'ec2:DescribeSecurityGroups',
        'ec2:DescribeInstances',
        'ec2:DescribeNetworkInterfaces',
        'ec2:DescribeAccountAttributes',
        'ec2:DescribeAddresses',
        'ec2:DescribeCoipPools',
        'ec2:DescribeTags',
        'ec2:GetCoipPoolUsage',
        'cognito-idp:DescribeUserPoolClient',
        'acm:ListCertificates',
        'acm:DescribeCertificate',
        'wafv2:GetWebACL',
        'wafv2:GetWebACLForResource',
        'shield:GetSubscriptionState',
        'shield:DescribeProtection',
      ],
      resources: ['*'],
    }));

    // Mutating ELB/EC2 actions scoped to resources owned by this cluster.
    const clusterOwnedCondition = {
      StringEquals: { [`aws:ResourceTag/kubernetes.io/cluster/${clusterName}`]: 'owned' },
    };
    lbcSa.role.addToPrincipalPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'elasticloadbalancing:CreateLoadBalancer',
        'elasticloadbalancing:CreateTargetGroup',
        'elasticloadbalancing:CreateListener',
        'elasticloadbalancing:CreateRule',
        'elasticloadbalancing:DeleteLoadBalancer',
        'elasticloadbalancing:DeleteTargetGroup',
        'elasticloadbalancing:DeleteListener',
        'elasticloadbalancing:DeleteRule',
        'elasticloadbalancing:ModifyLoadBalancerAttributes',
        'elasticloadbalancing:ModifyTargetGroup',
        'elasticloadbalancing:ModifyTargetGroupAttributes',
        'elasticloadbalancing:ModifyListener',
        'elasticloadbalancing:ModifyRule',
        'elasticloadbalancing:AddTags',
        'elasticloadbalancing:RemoveTags',
        'elasticloadbalancing:RegisterTargets',
        'elasticloadbalancing:DeregisterTargets',
        'elasticloadbalancing:SetWebAcl',
        'elasticloadbalancing:SetIpAddressType',
        'elasticloadbalancing:SetSecurityGroups',
        'elasticloadbalancing:SetSubnets',
        'ec2:CreateSecurityGroup',
        'ec2:DeleteSecurityGroup',
        'ec2:AuthorizeSecurityGroupIngress',
        'ec2:RevokeSecurityGroupIngress',
        'ec2:CreateTags',
        'ec2:DeleteTags',
        'wafv2:AssociateWebACL',
        'wafv2:DisassociateWebACL',
        'shield:CreateProtection',
        'shield:DeleteProtection',
      ],
      resources: ['*'],
      conditions: clusterOwnedCondition,
    }));

    // The controller needs CreateTags on newly created resources (before the
    // cluster-owned tag exists). Scope with a request-tag condition instead.
    lbcSa.role.addToPrincipalPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'elasticloadbalancing:CreateLoadBalancer',
        'elasticloadbalancing:CreateTargetGroup',
        'ec2:CreateSecurityGroup',
      ],
      resources: ['*'],
      conditions: {
        StringEquals: { [`aws:RequestTag/kubernetes.io/cluster/${clusterName}`]: 'owned' },
      },
    }));

    // CreateServiceLinkedRole scoped to the ELB service principal.
    lbcSa.role.addToPrincipalPolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['iam:CreateServiceLinkedRole'],
      resources: [`arn:${cdk.Aws.PARTITION}:iam::${cdk.Aws.ACCOUNT_ID}:role/aws-service-role/elasticloadbalancing.amazonaws.com/*`],
      conditions: {
        StringEquals: { 'iam:AWSServiceName': 'elasticloadbalancing.amazonaws.com' },
      },
    }));

    cluster.addHelmChart('AwsLoadBalancerController', {
      chart: 'aws-load-balancer-controller',
      repository: 'https://aws.github.io/eks-charts',
      namespace: 'kube-system',
      release: 'aws-load-balancer-controller',
      version: '1.10.0', // Compatible with K8s 1.30
      values: {
        clusterName: cluster.clusterName,
        serviceAccount: {
          create: false,
          name: 'aws-load-balancer-controller',
        },
        region: cdk.Aws.REGION,
        vpcId: vpc.vpcId,
      },
    });

    // --- cdk-nag suppressions: CDK-generated EKS infrastructure ---
    //
    // These resources are synthesized internally by the eks.Cluster L2 construct
    // (the cluster/kubectl custom-resource providers, their Lambda handlers, IAM
    // roles, and the waiter Step Function). Their IAM policies, Lambda runtimes,
    // and Step Function configuration are not exposed through any construct API,
    // so the findings below cannot be remediated in this stack — they are
    // suppressed with justification. Findings on resources this stack declares
    // directly (VPC flow logs, cluster endpoint/logging, node group and Load
    // Balancer Controller policies) are intentionally NOT suppressed here.
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      [
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/OnEventHandler/ServiceRole/Resource`,
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/IsCompleteHandler/ServiceRole/Resource`,
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/Provider/framework-onEvent/ServiceRole/Resource`,
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/Provider/framework-isComplete/ServiceRole/Resource`,
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/Provider/framework-onTimeout/ServiceRole/Resource`,
        `/${id}/@aws-cdk--aws-eks.KubectlProvider/Provider/framework-onEvent/ServiceRole/Resource`,
        `/${id}/Cluster/KubectlHandlerRole/Resource`,
        `/${id}/Cluster/Role/Resource`,
      ],
      [
        {
          id: 'AwsSolutions-IAM4',
          reason:
            'AWS-managed policies (AWSLambdaBasicExecutionRole, AWSLambdaVPCAccessExecutionRole, ' +
            'ECR read policies, AmazonEKSClusterPolicy) are attached by the CDK eks.Cluster ' +
            'construct to its internal custom-resource provider roles, kubectl handler role, and ' +
            'the cluster service role. These roles are not exposed for customization, and ' +
            'AmazonEKSClusterPolicy is required by Amazon EKS.',
        },
      ],
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      [
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/Provider/framework-onEvent/ServiceRole/DefaultPolicy/Resource`,
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/Provider/framework-isComplete/ServiceRole/DefaultPolicy/Resource`,
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/Provider/framework-onTimeout/ServiceRole/DefaultPolicy/Resource`,
        `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/Provider/waiter-state-machine/Role/DefaultPolicy/Resource`,
        `/${id}/@aws-cdk--aws-eks.KubectlProvider/Provider/framework-onEvent/ServiceRole/DefaultPolicy/Resource`,
        `/${id}/Cluster/Resource/CreationRole/DefaultPolicy/Resource`,
        `/${id}/Cluster/Resource/Resource/Default`,
      ],
      [
        {
          id: 'AwsSolutions-IAM5',
          reason:
            'Wildcard permissions are generated by the CDK custom-resource framework (Lambda ' +
            'invoke on internally-created handler ARNs, e.g. "<Handler>.Arn:*"), and by the ' +
            'cluster CreationRole which needs eks:*/fargateprofile scoped to the cluster it ' +
            'creates. These policies belong to CDK-managed resources and cannot be scoped further ' +
            'from this stack.',
        },
      ],
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      `/${id}/@aws-cdk--aws-eks.ClusterResourceProvider/Provider/waiter-state-machine/Resource`,
      [
        {
          id: 'AwsSolutions-SF1',
          reason:
            'The waiter Step Function is created internally by the CDK custom-resource framework; ' +
            'its logging configuration is not exposed for customization.',
        },
        {
          id: 'AwsSolutions-SF2',
          reason:
            'The waiter Step Function is created internally by the CDK custom-resource framework; ' +
            'X-Ray tracing is not exposed for customization.',
        },
      ],
    );
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      `/${id}/@aws-cdk--aws-eks.KubectlProvider/Handler/Resource`,
      [
        {
          id: 'AwsSolutions-L1',
          reason:
            'The kubectl handler Lambda runtime is pinned by the @aws-cdk/lambda-layer-kubectl-v30 ' +
            'package and the CDK KubectlProvider construct; it is not configurable from this stack.',
        },
      ],
    );

    // --- cdk-nag suppressions: intentional configuration on this stack's own resources ---

    // EKS1: the API server endpoint is intentionally PUBLIC_AND_PRIVATE. The
    // upgrade pipeline (DevOps Agent / Kiro CLI / GitHub Actions) reaches the
    // cluster from outside the VPC, so public endpoint access is required.
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      `/${id}/Cluster/Resource/Resource/Default`,
      [
        {
          id: 'AwsSolutions-EKS1',
          reason:
            'Public endpoint access is required so the off-VPC upgrade pipeline (DevOps Agent, ' +
            'Kiro CLI, GitHub Actions) can reach the cluster API server. Access is PUBLIC_AND_PRIVATE, ' +
            'not public-only.',
        },
      ],
    );

    // IAM4: the node group role uses the AWS-managed policies that Amazon EKS
    // requires for worker nodes. Replacing them with customer-managed copies
    // adds maintenance burden with no security benefit.
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      `/${id}/Cluster/NodegroupNodes/NodeGroupRole/Resource`,
      [
        {
          id: 'AwsSolutions-IAM4',
          reason:
            'AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy, and AmazonEC2ContainerRegistryReadOnly ' +
            'are the AWS-managed policies required by Amazon EKS worker nodes.',
          appliesTo: [
            'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEKSWorkerNodePolicy',
            'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEKS_CNI_Policy',
            'Policy::arn:<AWS::Partition>:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly',
          ],
        },
      ],
    );

    // IAM5: the AWS Load Balancer Controller policy is the upstream-canonical
    // policy. The read-only Describe* wildcard cannot be scoped (the controller
    // discovers resources dynamically at runtime); the mutating actions are
    // already constrained with cluster-owned/request-tag conditions in the
    // policy statements above; and iam:CreateServiceLinkedRole is scoped to the
    // ELB service-linked-role path, which inherently ends in a wildcard.
    NagSuppressions.addResourceSuppressionsByPath(
      this,
      `/${id}/Cluster/AwsLoadBalancerController/Role/DefaultPolicy/Resource`,
      [
        {
          id: 'AwsSolutions-IAM5',
          reason:
            'Canonical AWS Load Balancer Controller policy. Read-only Describe* actions cannot be ' +
            'ARN-scoped (runtime resource discovery); mutating actions are constrained with ' +
            'kubernetes.io/cluster ownership and request-tag conditions; the service-linked-role ' +
            'resource path is inherently a wildcard.',
          appliesTo: [
            'Action::elasticloadbalancing:Describe*',
            'Resource::*',
            'Resource::arn:<AWS::Partition>:iam::<AWS::AccountId>:role/aws-service-role/elasticloadbalancing.amazonaws.com/*',
          ],
        },
      ],
    );
  }
}
