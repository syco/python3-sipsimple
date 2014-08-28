
import weakref


cdef class VideoProducer:

    def __init__(self):
        self._consumers = set()

    def __cinit__(self, *args, **kwargs):
        cdef PJSIPUA ua
        cdef pj_pool_t *pool
        cdef int status
        cdef bytes lock_name, pool_name

        ua = _get_ua()
        lock_name = b"VideoProducer_lock_%d" % id(self)
        pool_name = b"VideoProducer_pool_%d" % id(self)

        pool = ua.create_memory_pool(pool_name, 4096, 4096)
        self._pool = pool

        status = pj_mutex_create_recursive(pool, lock_name, &self._lock)
        if status != 0:
            raise PJSIPError("Could not create lock", status)
        self._running = 0
        self._started = 0
        self._closed = 0

    property consumers:

        def __get__(self):
            cdef pj_mutex_t *lock
            lock = self._lock

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                return self._consumers.copy()
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

    property closed:

        def __get__(self):
            cdef pj_mutex_t *lock
            lock = self._lock

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                return bool(self._closed)
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

    cdef void _add_consumer(self, VideoConsumer consumer):
        raise NotImplementedError

    cdef void _remove_consumer(self, VideoConsumer consumer):
        raise NotImplementedError

    def start(self):
        raise NotImplementedError

    def stop(self):
        raise NotImplementedError

    def close(self):
        raise NotImplementedError


cdef class VideoConsumer:

    def __init__(self):
        self._producer = None

    def __cinit__(self, *args, **kwargs):
        cdef PJSIPUA ua
        cdef pj_pool_t *pool
        cdef int status
        cdef bytes lock_name, pool_name

        self.weakref = weakref.ref(self)
        Py_INCREF(self.weakref)

        ua = _get_ua()
        lock_name = b"VideoConsumer_lock_%d" % id(self)
        pool_name = b"VideoConsumer_pool_%d" % id(self)

        pool = ua.create_memory_pool(pool_name, 4096, 4096)
        self._pool = pool

        status = pj_mutex_create_recursive(pool, lock_name, &self._lock)
        if status != 0:
            raise PJSIPError("Could not create lock", status)
        self._running = 0
        self._closed = 0

    def __dealloc__(self):
        # cython will always the __dealloc__ method of the parent class *after* the child's
        # __dealloc__ was executed
        cdef PJSIPUA ua
        cdef Timer timer
        try:
            ua = _get_ua()
        except:
            return
        if self._lock != NULL:
            pj_mutex_destroy(self._lock)
        ua.release_memory_pool(self._pool)
        timer = Timer()
        try:
            timer.schedule(60, deallocate_weakref, self.weakref)
        except SIPCoreError:
            pass

    property producer:

        def __get__(self):
            cdef pj_mutex_t *lock
            lock = self._lock

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                if self._closed:
                    return None
                return self._producer
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

        def __set__(self, value):
            cdef pj_mutex_t *lock
            lock = self._lock

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                if self._closed:
                    return
                self._set_producer(value)
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

    property closed:

        def __get__(self):
            cdef pj_mutex_t *lock
            lock = self._lock

            with nogil:
                status = pj_mutex_lock(lock)
            if status != 0:
                raise PJSIPError("failed to acquire lock", status)
            try:
                return bool(self._closed)
            finally:
                with nogil:
                    pj_mutex_unlock(lock)

    cdef void _set_producer(self, VideoProducer producer):
        # Called to set producer, which can be None. Must set self._producer.
        # No need to hold the lock or check for closed state.
        raise NotImplementedError

    def close(self):
        raise NotImplementedError


cdef class VideoCamera(VideoProducer):
    # NOTE: we use a video tee to be able to send the video to multiple consumers at the same
    # time. The video tee, however, is not thread-safe, so we need to make sure the source port
    # is stopped before adding or removing a destination port.

    def __init__(self, unicode device, str resolution='auto', int fps=25):
        cdef pjmedia_vid_port_param vp_param
        cdef pjmedia_vid_dev_info vdi
        cdef pjmedia_vid_port *video_port
        cdef pjmedia_port *video_tee
        cdef pjmedia_format fmt
        cdef pj_mutex_t *lock
        cdef pj_pool_t *pool
        cdef int status
        cdef int device_id
        cdef int dev_count
        cdef int width
        cdef int height
        cdef object res

        resolution = resolution.lower()
        if resolution == 'vga':
            res = (640, 480)
        elif resolution in ('auto', '720p'):
            res = (1280, 720)
        elif resolution == '1080p':
            res = (1920, 1080)
        else:
            raise ValueError('invalid resolution specified: %s' % resolution)

        super(VideoCamera, self).__init__()

        lock = self._lock
        pool = self._pool

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._video_port != NULL:
                raise SIPCoreError("VideoCamera.__init__() was already called")

            dev_count = pjmedia_vid_dev_count()
            if dev_count == 0:
                raise SIPCoreError("no video devices available")

            device_id = PJMEDIA_VID_DEFAULT_CAPTURE_DEV

            # Find the device matching the name
            if device != u"system_default":
                for i in range(dev_count):
                    with nogil:
                        status = pjmedia_vid_dev_get_info(i, &vdi)
                    if status != 0:
                        continue
                    if vdi.dir in (PJMEDIA_DIR_CAPTURE, PJMEDIA_DIR_CAPTURE_PLAYBACK) and decode_device_name(vdi.name) == device:
                        device_id = vdi.id
                        break

            # Set device name
            self.name = device
            with nogil:
                status = pjmedia_vid_dev_get_info(device_id, &vdi)
            if status != 0:
                raise PJSIPError("Could not get video device info", status)
            self.real_name = decode_device_name(vdi.name)

            pjmedia_vid_port_param_default(&vp_param)
            with nogil:
                status = pjmedia_vid_dev_default_param(pool, device_id, &vp_param.vidparam)
            if status != 0:
                raise PJSIPError("Could not get video device default parameters", status)

            # Create capture video port
            vp_param.active = 1
            vp_param.vidparam.dir = PJMEDIA_DIR_CAPTURE
            # Set maximum possible resolution
            width, height = res
            vp_param.vidparam.fmt.det.vid.size.w = width
            vp_param.vidparam.fmt.det.vid.size.h = height
            # Set maximum fps
            vp_param.vidparam.fmt.det.vid.fps.num = int(fps)
            vp_param.vidparam.fmt.det.vid.fps.denum = 1
            with nogil:
                status = pjmedia_vid_port_create(pool, &vp_param, &video_port)
            if status != 0:
                raise PJSIPError("Could not create capture video port", status)
            self._video_port = video_port

            # Get format info
            fmt = vp_param.vidparam.fmt

            # Create video tee
            with nogil:
                status = pjmedia_vid_tee_create(pool, &fmt, 255, &video_tee)
            if status != 0:
                raise PJSIPError("Could not create video tee", status)
            self._video_tee = video_tee

            # Connect capture and video tee ports
            with nogil:
                status = pjmedia_vid_port_connect(video_port, video_tee, 0)
            if status != 0:
                raise PJSIPError("Could not connect video capture and tee ports", status)
            self.producer_port = self._video_tee
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def start(self):
        cdef int status
        cdef pj_mutex_t *lock

        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                raise SIPCoreError("video device is closed")
            if self._started:
                return
            if self._consumers:
                self._start()
            self._started = 1
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def stop(self):
        cdef int status
        cdef pj_mutex_t *lock

        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                raise SIPCoreError("video device is closed")
            if not self._started:
                return
            self._stop()
            self._started = 0
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    def close(self):
        cdef int status
        cdef pj_mutex_t *lock
        cdef PJSIPUA ua

        try:
            ua = _get_ua()
        except:
            return

        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                return
            _stop_video_port(self._video_port)
            for c in self._consumers.copy():
                c.producer = None
            self._stop()
            self._started = 0
            self._closed = 1
            if self._video_port != NULL:
                with nogil:
                    pjmedia_vid_port_stop(self._video_port)
                    pjmedia_vid_port_disconnect(self._video_port)
                    pjmedia_vid_port_destroy(self._video_port)
                self._video_port = NULL
            if self._video_tee != NULL:
                with nogil:
                    pjmedia_port_destroy(self._video_tee)
                self._video_tee = NULL
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef void _add_consumer(self, VideoConsumer consumer):
        cdef int status
        cdef pj_mutex_t *lock
        cdef pjmedia_port *consumer_port
        cdef pjmedia_port *producer_port

        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                raise SIPCoreError("video device is closed")
            if consumer in self._consumers:
                return
            consumer_port = consumer.consumer_port
            producer_port = self.producer_port
            _stop_video_port(self._video_port)
            with nogil:
                status = pjmedia_vid_tee_add_dst_port2(producer_port, 0, consumer_port)
            if status != 0:
                raise PJSIPError("Could not connect video consumer with producer", status)
            self._consumers.add(consumer)
            if self._started:
                _start_video_port(self._video_port)
                self._start()
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef void _remove_consumer(self, VideoConsumer consumer):
        cdef int status
        cdef pj_mutex_t *lock

        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                raise SIPCoreError("video device is closed")
            if consumer not in self._consumers:
                return
            consumer_port = consumer.consumer_port
            producer_port = self.producer_port
            _stop_video_port(self._video_port)
            with nogil:
                status = pjmedia_vid_tee_remove_dst_port(producer_port, consumer_port)
            if status != 0:
                raise PJSIPError("Could not disconnect video consumer from producer", status)
            self._consumers.remove(consumer)
            if not self._consumers:
                self._stop()
            elif self._started:
                _start_video_port(self._video_port)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef void _start(self):
        # No need to hold the lock, this function is always called with it held
        if self._running:
            return
        _start_video_port(self._video_port)
        self._running = 1

    cdef void _stop(self):
        # No need to hold the lock, this function is always called with it held
        if not self._running:
            return
        _stop_video_port(self._video_port)
        self._running = 0

    def __dealloc__(self):
        cdef PJSIPUA ua
        try:
            ua = _get_ua()
        except:
            return
        if self._video_port != NULL:
            with nogil:
                pjmedia_vid_port_stop(self._video_port)
                pjmedia_vid_port_disconnect(self._video_port)
                pjmedia_vid_port_destroy(self._video_port)
        if self._video_tee != NULL:
            with nogil:
                pjmedia_port_destroy(self._video_tee)
        if self._lock != NULL:
            pj_mutex_destroy(self._lock)
        ua.release_memory_pool(self._pool)


cdef class LocalVideoStream(VideoConsumer):

    cdef void _initialize(self, pjmedia_port *media_port):
        self.consumer_port = media_port
        self._running = 1
        self._closed = 0

    cdef void _set_producer(self, VideoProducer producer):
        old_producer = self._producer
        if old_producer is producer:
            return
        if old_producer is not None and not old_producer.closed:
            old_producer._remove_consumer(self)
        self._producer = producer
        if producer is not None:
            producer._add_consumer(self)

    def close(self):
        cdef int status
        cdef pj_mutex_t *lock
        cdef PJSIPUA ua

        try:
            ua = _get_ua()
        except:
            return

        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                return
            self._set_producer(None)
            self._closed = 1
        finally:
            with nogil:
                pj_mutex_unlock(lock)


cdef LocalVideoStream_create(pjmedia_vid_stream *stream):
    cdef pjmedia_port *media_port
    cdef int status

    with nogil:
        status = pjmedia_vid_stream_get_port(stream, PJMEDIA_DIR_ENCODING, &media_port)
    if status != 0:
        raise PJSIPError("failed to get video stream port", status)
    if media_port == NULL:
        raise ValueError("invalid media port")

    obj = LocalVideoStream()
    obj._initialize(media_port)
    return obj


cdef class RemoteVideoStream(VideoProducer):

    cdef void _initialize(self, pjmedia_port *media_port):
        # TODO: we cannot use a tee here, because the remote video is a passive port, we have a pjmedia_port, not a
        # pjmedia_vid_port, so, for now, only one consumer is allowed
        self.producer_port = media_port
        self._running = 1
        self._closed = 0

    def start(self):
        pass

    def stop(self):
        pass

    def close(self):
        cdef int status
        cdef pj_mutex_t *lock
        cdef PJSIPUA ua
        cdef VideoConsumer consumer

        try:
            ua = _get_ua()
        except:
            return

        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                return
            if self._consumers:
                consumer = self._consumers.pop()
                consumer.producer = None
            self._closed = 1
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef void _add_consumer(self, VideoConsumer consumer):
        cdef int status
        cdef pj_mutex_t *lock
        cdef pjmedia_port *producer_port
        cdef pjmedia_vid_port *consumer_port
        cdef PJSIPUA ua

        ua = _get_ua()
        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                raise SIPCoreError("producer is closed")
            if consumer in self._consumers:
                return
            if self._consumers:
                raise SIPCoreError("another consumer is already attached to this producer")
            consumer_port = consumer._video_port
            producer_port = self.producer_port
            with nogil:
                status = pjmedia_vid_port_connect(consumer_port, producer_port, 0)
            if status != 0:
                raise PJSIPError("Could not connect video consumer with producer", status)
            self._consumers.add(consumer)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef void _remove_consumer(self, VideoConsumer consumer):
        cdef int status
        cdef pj_mutex_t *lock
        cdef PJSIPUA ua
        cdef pjmedia_vid_port *consumer_port

        ua = _get_ua()
        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                raise SIPCoreError("producer is closed")
            if consumer not in self._consumers:
                return
            consumer_port = consumer._video_port
            with nogil:
                status = pjmedia_vid_port_disconnect(consumer_port)
            if status != 0:
                raise PJSIPError("Could not disconnect video consumer from producer", status)
            self._consumers.remove(consumer)
        finally:
            with nogil:
                pj_mutex_unlock(lock)


cdef class FrameBufferVideoRenderer(VideoConsumer):

    def __init__(self, frame_handler):
        super(FrameBufferVideoRenderer, self).__init__()
        if not callable(frame_handler):
            raise TypeError('frame_handler must be callable')
        self._frame_handler = frame_handler

    cdef _initialize(self, VideoProducer producer):
        cdef pjmedia_vid_port_param vp_param
        cdef pjmedia_vid_port *video_port
        cdef pjmedia_vid_dev_stream *video_stream
        cdef pjmedia_format fmt
        cdef pjmedia_port *consumer_port
        cdef pj_pool_t *pool
        cdef pj_mutex_t *lock
        cdef int status
        cdef int index
        cdef void *ptr

        lock = self._lock
        pool = self._pool

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._video_port != NULL:
                raise RuntimeError("object already initialized")

            if not isinstance(producer, (VideoCamera, RemoteVideoStream)):
                raise TypeError("unsupported producer type: %s" % producer.__class__)

            status = pjmedia_vid_dev_lookup("FrameBuffer", "FrameBuffer renderer", &index)
            if status != 0:
                raise PJSIPError("Could not get render video device index", status)
            pjmedia_vid_port_param_default(&vp_param)
            with nogil:
                status = pjmedia_vid_dev_default_param(pool, index, &vp_param.vidparam)
            if status != 0:
                raise PJSIPError("Could not get render video device default parameters", status)
            fmt = producer.producer_port.info.fmt
            vp_param.active = 0 if isinstance(producer, VideoCamera) else 1
            vp_param.vidparam.dir = PJMEDIA_DIR_RENDER;
            vp_param.vidparam.fmt = fmt
            vp_param.vidparam.disp_size = fmt.det.vid.size
            vp_param.vidparam.flags = 0

            with nogil:
                status = pjmedia_vid_port_create(pool, &vp_param, &video_port)
            if status != 0:
                raise PJSIPError("Could not create consumer video port", status)
            self._video_port = video_port

            if not vp_param.active:
                with nogil:
                    consumer_port = pjmedia_vid_port_get_passive_port(video_port)
                if consumer_port == NULL:
                    raise SIPCoreError("Could not get passive video port")
            else:
                consumer_port = NULL
            self.consumer_port = consumer_port

            with nogil:
                video_stream = pjmedia_vid_port_get_stream(video_port)
            if video_stream == NULL:
                raise SIPCoreError("invalid video device stream")
            self._video_stream = video_stream

            ptr = <void*>self.weakref
            status = pjmedia_vid_dev_fb_set_callback(video_stream, FrameBufferVideoRenderer_frame_handler, ptr)
            if status != 0:
                raise PJSIPError("Could not set frame handler callback", status)
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef void _set_producer(self, VideoProducer producer):
        old_producer = self._producer
        if old_producer is producer:
            return

        # initialize our port if not initialized
        if self._video_port == NULL:
            self._initialize(producer)

        self._stop()
        if old_producer is not None:
            old_producer._remove_consumer(self)
        self._producer = producer
        if producer is not None:
            producer._add_consumer(self)
            self._start()

    def close(self):
        cdef int status
        cdef pj_mutex_t *lock
        cdef pjmedia_vid_port *video_port
        cdef PJSIPUA ua
        cdef void* ptr

        try:
            ua = _get_ua()
        except:
            return

        lock = self._lock

        with nogil:
            status = pj_mutex_lock(lock)
        if status != 0:
            raise PJSIPError("failed to acquire lock", status)
        try:
            if self._closed:
                return
            self._set_producer(None)
            self._stop()
            self._closed = 1
            video_port = self._video_port
            if video_port != NULL:
                with nogil:
                    pjmedia_vid_port_stop(video_port)
                    pjmedia_vid_port_disconnect(video_port)
                    pjmedia_vid_port_destroy(video_port)
            self._video_port = NULL
        finally:
            with nogil:
                pj_mutex_unlock(lock)

    cdef void _start(self):
        # No need to hold the lock, this function is always called with it held
        if self._running:
            return
        _start_video_port(self._video_port)
        self._running = 1

    cdef void _stop(self):
        # No need to hold the lock, this function is always called with it held
        if not self._running:
            return
        _stop_video_port(self._video_port)
        self._running = 0

    def __dealloc__(self):
        cdef PJSIPUA ua
        cdef pjmedia_vid_port *video_port
        try:
            ua = _get_ua()
        except:
            return
        video_port = self._video_port
        if video_port != NULL:
            with nogil:
                pjmedia_vid_port_stop(video_port)
                pjmedia_vid_port_disconnect(video_port)
                pjmedia_vid_port_destroy(video_port)
        self._video_port = NULL


cdef RemoteVideoStream_create(pjmedia_vid_stream *stream):
    cdef pjmedia_port *media_port
    cdef int status

    with nogil:
        status = pjmedia_vid_stream_get_port(stream, PJMEDIA_DIR_DECODING, &media_port)
    if status != 0:
        raise PJSIPError("failed to get video stream port", status)
    if media_port == NULL:
        raise ValueError("invalid media port")

    obj = RemoteVideoStream()
    obj._initialize(media_port)
    return obj


cdef void _start_video_port(pjmedia_vid_port *port):
    cdef int status
    with nogil:
        status = pjmedia_vid_port_start(port)
    if status != 0:
        raise PJSIPError("Could not start video port", status)


cdef void _stop_video_port(pjmedia_vid_port *port):
    cdef int status
    with nogil:
        status = pjmedia_vid_port_stop(port)
    if status != 0:
        raise PJSIPError("Could not start video port", status)


cdef void FrameBufferVideoRenderer_frame_handler(pjmedia_frame_ptr_const frame, pjmedia_rect_size size, void *user_data) with gil:
    cdef PJSIPUA ua
    cdef FrameBufferVideoRenderer rend
    try:
        ua = _get_ua()
    except:
        return
    if user_data == NULL:
        return
    rend = (<object> user_data)()
    if rend is None:
        return
    if rend._frame_handler is not None:
        data = PyString_FromStringAndSize(<char*>frame.buf, frame.size)
        rend._frame_handler(data, size.w, size.h)
