# -*- coding: utf-8 -*-
import os
import zmq
import json
import uuid
import tempfile
import subprocess
from CTPStruct import *
from message import *


def packageReqInfo(apiName,data):
	'''
	获取一个默认的调用结构
	'''
	reqInfo = {}
	reqInfo['RequestMethod'] = apiName
	parameters = {}
	reqInfo['Parameters'] = parameters
	parameters['Data'] = data
	return reqInfo

# 定义通用的出错返回数据
InvalidRequestFormat = [-2000,u'参数表单类型不正确',[]]
ResponseTimeOut = [-2001,u'请求超时未响应',[]]
InvalidRequestFormat = [-2002,u'接收到异常消息格式',[]]





class CTPChannel :
	'''
	CTP通讯管道类,该类和CTPConverter进程通讯,对外实现python语言封装的CTP接口,在设计上该类
	既支持同步接口也支持异步接口,但是目前暂时先实现同步接口.
	'''
	def __mallocIpcAddress(self):
	    return 'ipc://%s/%s' % (tempfile.gettempdir(),uuid.uuid1())

	def __testChannel(self):
		'''
		检查ctp交易通道是否运行正常，该方法在构造函数内调用如果失败，构造函数会抛出异常
		成功返回True，失败返回False
		'''
		data = CThostFtdcQryTradingAccountField()
		result = self.QryTradingAccount(data)
		return result[0] == 0

	def __delTraderProcess(self):
		'''
		清除trader转换器进程
		'''
		self.traderProcess.kill()
		self.traderProcess.wait()


	def __init__(self,frontAddress,brokerID,userID,password,fileOutput='/dev/null'):
		'''
		初始化过程
		1.创建ctp转换器进程
		2.创建和ctp通讯进程的通讯管道
		3.测试ctp连接是否正常
		如果ctp连接测试失败，将抛出异常阻止对象的创建
		'''
		# 为ctp转换器分配通讯管道地址
		self.requestPipe = self.__mallocIpcAddress()
		self.pushbackPipe = self.__mallocIpcAddress()
		self.publishPipe = self.__mallocIpcAddress()

		# 构造调用命令
		commandLine = ['trader',
		'--FrontAddress',frontAddress,
		'--BrokerID',brokerID,
		'--UserID',userID,
		'--Password', password,
		'--RequestPipe', self.requestPipe,
		'--PushbackPipe', self.pushbackPipe,
		'--PublishPipe', self.publishPipe,
		]

		# 创建转换器子进程
		devnull = open(fileOutput, 'w')
		self.traderProcess = subprocess.Popen(commandLine,stdout=devnull)

		# 创建请求通讯通道
		context = zmq.Context()
		self.context = context
		socket = context.socket(zmq.DEALER)
		socket.connect(self.requestPipe)
		socket.setsockopt(zmq.LINGER,0)
		self.request = socket
		self.timeout = 1000 * 1

		# 检查ctp通道是否建立，如果失败抛出异常
		if not self.__testChannel():
			self.__delTraderProcess()
			raise Exception('无法建立ctp连接,具体错误请查看ctp转换器的日志信息')
			#raise Exception('''can't not connect to ctp server.''')


	def __del__(self):
		'''
		对象移出过程
		1.结束ctp转换器进程
		'''
		self.__delTraderProcess()




{% for method in reqMethodDict.itervalues() %}
	{% set parameter = method['parameters'][0]  %}
	def {{ method['name'][3:]}}(self,data):
		'''
		{{ method['remark'][3:] }}
		data 调用api需要填写参数表单,类型为{{parameter['raw_type']}},具体参见其定义文件
		返回信息格式[errorID,errorMsg,responseData=[...]]
		注意:同步调用没有metaData参数,因为没有意义
		'''
		if not isinstance(data,{{parameter['raw_type']}}):
			return InvalidRequestFormat

		requestApiName = 'Req{{method['name'][3:]}}'
		responseApiName = 'OnRsp{{method['name'][3:]}}'

		# 打包消息格式
		reqInfo = packageReqInfo(requestApiName,data.toDict())
		metaData={}
		requestMessage = RequestMessage()
		requestMessage.header = 'REQUEST'
		requestMessage.apiName = requestApiName
		requestMessage.reqInfo = json.dumps(reqInfo)
		requestMessage.metaData = json.dumps(metaData)

		# 发送到服务器
		requestMessage.send(self.request)

		################### 等待服务器的REQUESTID响应 ###################
		# 读取服务
		poller = zmq.Poller()
		poller.register(self.request, zmq.POLLIN)
		sockets = dict(poller.poll(self.timeout))
		if not (self.request in sockets) :
			return ResponseTimeOut

		# 从request通讯管道读取返回信息
		requestIDMessage = RequestIDMessage()
		requestIDMessage.recv(self.request)

		# 检查接收的消息格式
		c1 = requestIDMessage.header == 'REQUESTID'
		c2 = requestIDMessage.apiName == requestApiName
		if not ( c1 and c2 ):
			return InvalidRequestFormat

		# 如果没有收到RequestID,返回转换器的出错信息
		if not (int(requestIDMessage.requestID) > 0):
			errorInfo = json.loads(requestIDMessage.errorInfo)
			return errorInfo['ErrorID'],errorInfo['ErrorMsg'],[]


		################### 等待服务器的返回的数据信息 ###################
		poller = zmq.Poller()
		poller.register(self.request, zmq.POLLIN)

		# 循环读取所有数据
		respnoseDataList = []
		while(True):
			sockets = dict(poller.poll(self.timeout))
			if not (self.request in sockets) :
				return ResponseTimeOut

			# 从request通讯管道读取返回信息
			responseMessage = ResponseMessage()
			responseMessage.recv(self.request)

			# 返回数据信息格式符合要求
			c1 = responseMessage.header == 'RESPONSE'
			c2 = responseMessage.requestID == requestIDMessage.requestID
			c3 = responseMessage.apiName == responseApiName
			if not (c1 and c2 and c3) :
				return InvalidRequestFormat

			# 提取消息中的出错信息
			#print responseMessage.respInfo
			respInfo = json.loads(responseMessage.respInfo)
			errorID = respInfo['Parameters']['RspInfo']['ErrorID']
			errorMsg = respInfo['Parameters']['RspInfo']['ErrorMsg']
			if errorID != 0 :
				return errorID,errorMsg,[]

			# 提取消息中的数据
			{% set responseDataType = onRspMethodDict['OnRsp' + method['name'][3:]]['parameters'][0]['raw_type']%}
			respnoseDataDict = respInfo['Parameters']['Data']
			if respnoseDataDict:
				respnoseData = {{responseDataType}}(**respnoseDataDict)
				respnoseDataList.append(respnoseData)

			# 判断是否已是最后一条消息
			if int(responseMessage.isLast) == 1:
				break;

		# 返回成功
		return 0,'',respnoseDataList



{% endfor %}