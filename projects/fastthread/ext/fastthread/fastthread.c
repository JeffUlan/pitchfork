/*
 * Optimized Ruby Mutex implementation, loosely based on thread.rb by
 * Yukihiro Matsumoto <matz@ruby-lang.org>
 *
 *  Copyright 2006-2007  MenTaLguY <mental@rydia.net>
 *
 * This file is made available under the same terms as Ruby.
 */

#include <ruby.h>
#include <intern.h>
#include <rubysig.h>

static VALUE avoid_mem_pools;

#ifndef USE_MEM_POOLS
#define USE_MEM_POOLS !RTEST(avoid_mem_pools)
#endif

static VALUE rb_cMutex;
static VALUE rb_cConditionVariable;
/* post-1.8.5 Ruby exposes rb_eThreadError; earlier versions do not */
static VALUE private_eThreadError;
static VALUE rb_cQueue;
static VALUE rb_cSizedQueue;

static VALUE
return_value(value)
  VALUE value;
{
  return value;
}

typedef struct _Entry {
  VALUE value;
  struct _Entry *next;
} Entry;

typedef struct _List {
  Entry *entries;
  Entry *last_entry;
  Entry *entry_pool;
  unsigned long size;
} List;

static void init_list _((List *));

static void
init_list(list)
  List *list;
{
  list->entries = NULL;
  list->last_entry = NULL;
  list->entry_pool = NULL;
  list->size = 0;
}

static void mark_list _((List *));

static void
mark_list(list)
  List *list;
{
  Entry *entry;
  for ( entry = list->entries ; entry ; entry = entry->next ) {
    rb_gc_mark(entry->value);
  }
}

static void free_entries _((Entry *));

static void
free_entries(first)
  Entry *first;
{
  Entry *next;
  while (first) {
    next = first->next;
    free(first);
    first = next;
  }
}

static void finalize_list _((List *));

static void
finalize_list(list)
  List *list;
{
  free_entries(list->entries);
  free_entries(list->entry_pool);
}

static void push_list _((List *, VALUE));

static void
push_list(list, value)
  List *list;
  VALUE value;
{
  Entry *entry;

  if (list->entry_pool) {
    entry = list->entry_pool;
    list->entry_pool = entry->next;
  } else {
    entry = (Entry *)malloc(sizeof(Entry));
  }

  entry->value = value;
  entry->next = NULL;

  if (list->last_entry) {
    list->last_entry->next = entry;
  } else {
    list->entries = entry;
  }
  list->last_entry = entry;

  ++list->size;
}

static void push_multiple_list _((List *, VALUE *, unsigned));

static void
push_multiple_list(list, values, count)
  List *list;
  VALUE *values;
  unsigned count;
{
  unsigned i;
  for ( i = 0 ; i < count ; i++ ) {
    push_list(list, values[i]);
  }
}

static VALUE shift_list _((List *));

static VALUE
shift_list(list)
  List *list;
{
  Entry *entry;
  VALUE value;

  entry = list->entries;
  if (!entry) return Qundef;

  list->entries = entry->next;
  if ( entry == list->last_entry ) {
    list->last_entry = NULL;
  }

  --list->size;

  value = entry->value;
  if (USE_MEM_POOLS) {
    entry->next = list->entry_pool;
    list->entry_pool = entry;
  } else {
    free(entry);
  }

  return value;
}

static void clear_list _((List *));

static void
clear_list(list)
  List *list;
{
  if (list->last_entry) {
    if (USE_MEM_POOLS) {
      list->last_entry->next = list->entry_pool;
      list->entry_pool = list->entries;
    } else {
      free_entries(list->entries);
    }
    list->entries = NULL;
    list->last_entry = NULL;
    list->size = 0;
  }
}

static VALUE array_from_list _((List const *));

static VALUE
array_from_list(list)
  List const *list;
{
  VALUE ary;
  Entry *entry;
  ary = rb_ary_new();
  for ( entry = list->entries ; entry ; entry = entry->next ) {
    rb_ary_push(ary, entry->value);
  }
  return ary;
}

static VALUE wake_thread _((VALUE));

static VALUE
wake_thread(thread)
  VALUE thread;
{
  return rb_rescue2(rb_thread_wakeup, thread,
                    return_value, Qnil, private_eThreadError, 0);
}

static VALUE run_thread _((VALUE));

static VALUE
run_thread(thread)
  VALUE thread;
{
  return rb_rescue2(rb_thread_run, thread,
                    return_value, Qnil, private_eThreadError, 0);
}

static VALUE wake_one _((List *));

static VALUE
wake_one(list)
  List *list;
{
  VALUE waking;

  waking = Qnil;
  while ( list->entries && !RTEST(waking) ) {
    waking = wake_thread(shift_list(list));
  }

  return waking;
}

static VALUE wake_all _((List *));

static VALUE
wake_all(list)
  List *list;
{
  while (list->entries) {
    wake_one(list);
  }
  return Qnil;
}

static void assert_no_survivors _((List *, const char *, void *));

static void
assert_no_survivors(waiting, label, addr)
  List *waiting;
  const char *label;
  void *addr;
{
  Entry *entry;
  for ( entry = waiting->entries ; entry ; entry = entry->next ) {
    if (RTEST(wake_thread(entry->value))) {
      rb_bug("%s %p freed with live thread(s) waiting", label, addr);
    }
  }
}

typedef struct _Mutex {
  VALUE owner;
  List waiting;
} Mutex;

static void mark_mutex _((Mutex *));

static void
mark_mutex(mutex)
  Mutex *mutex;
{
  rb_gc_mark(mutex->owner);
  mark_list(&mutex->waiting);
}

static void finalize_mutex _((Mutex *));

static void
finalize_mutex(mutex)
  Mutex *mutex;
{
  finalize_list(&mutex->waiting);
}

static void free_mutex _((Mutex *));

static void
free_mutex(mutex)
  Mutex *mutex;
{
  assert_no_survivors(&mutex->waiting, "mutex", mutex);
  finalize_mutex(mutex);
  free(mutex);
}

static void init_mutex _((Mutex *));

static void
init_mutex(mutex)
  Mutex *mutex;
{
  mutex->owner = Qnil;
  init_list(&mutex->waiting);
}

static VALUE rb_mutex_alloc _((VALUE));

static VALUE 
rb_mutex_alloc(klass)
  VALUE klass;
{
  Mutex *mutex;
  mutex = (Mutex *)malloc(sizeof(Mutex));
  init_mutex(mutex);
  return Data_Wrap_Struct(klass, mark_mutex, free_mutex, mutex);
}

static VALUE rb_mutex_locked_p _((VALUE));

static VALUE
rb_mutex_locked_p(self)
  VALUE self;
{
  Mutex *mutex;
  Data_Get_Struct(self, Mutex, mutex);
  return ( RTEST(mutex->owner) ? Qtrue : Qfalse );
}

static VALUE rb_mutex_try_lock _((VALUE));

static VALUE
rb_mutex_try_lock(self)
  VALUE self;
{
  Mutex *mutex;
  VALUE result;

  Data_Get_Struct(self, Mutex, mutex);

  result = Qfalse;

  rb_thread_critical = 1;
  if (!RTEST(mutex->owner)) {
    mutex->owner = rb_thread_current();
    result = Qtrue;
  }
  rb_thread_critical = 0;

  return result;
}

static void lock_mutex _((Mutex *));

static void
lock_mutex(mutex)
  Mutex *mutex;
{
  VALUE current;
  current = rb_thread_current();

  rb_thread_critical = 1;

  while (RTEST(mutex->owner)) {
    push_list(&mutex->waiting, current);
    rb_thread_stop();

    rb_thread_critical = 1;
  }
  mutex->owner = current; 

  rb_thread_critical = 0;
}

static VALUE rb_mutex_lock _((VALUE));

static VALUE
rb_mutex_lock(self)
  VALUE self;
{
  Mutex *mutex;
  Data_Get_Struct(self, Mutex, mutex);
  lock_mutex(mutex);
  return self;
}

static VALUE unlock_mutex_inner _((Mutex *));

static VALUE
unlock_mutex_inner(mutex)
  Mutex *mutex;
{
  VALUE waking;

  if (!RTEST(mutex->owner)) {
    return Qundef;
  }
  mutex->owner = Qnil;
  waking = wake_one(&mutex->waiting);

  return waking;
}

static VALUE set_critical _((VALUE));

static VALUE
set_critical(value)
  VALUE value;
{
  rb_thread_critical = (int)value;
  return Qnil;
}

static VALUE unlock_mutex _((Mutex *));

static VALUE
unlock_mutex(mutex)
  Mutex *mutex;
{
  VALUE waking;

  rb_thread_critical = 1;
  waking = rb_ensure(unlock_mutex_inner, (VALUE)mutex, set_critical, 0);

  if ( waking == Qundef ) {
    return Qfalse;
  }

  if (RTEST(waking)) {
    run_thread(waking);
  }

  return Qtrue;
}

static VALUE rb_mutex_unlock _((VALUE));

static VALUE
rb_mutex_unlock(self)
  VALUE self;
{
  Mutex *mutex;
  Data_Get_Struct(self, Mutex, mutex);

  if (RTEST(unlock_mutex(mutex))) {
    return self;
  } else {
    return Qnil;
  }
}

static VALUE rb_mutex_exclusive_unlock_inner _((Mutex *));

static VALUE
rb_mutex_exclusive_unlock_inner(mutex)
  Mutex *mutex;
{
  VALUE waking;
  waking = unlock_mutex_inner(mutex);
  rb_yield(Qundef);
  return waking;
}

static VALUE rb_mutex_exclusive_unlock _((VALUE));

static VALUE
rb_mutex_exclusive_unlock(self)
  VALUE self;
{
  Mutex *mutex;
  VALUE waking;
  Data_Get_Struct(self, Mutex, mutex);

  rb_thread_critical = 1;
  waking = rb_ensure(rb_mutex_exclusive_unlock_inner, (VALUE)mutex, set_critical, 0);

  if ( waking == Qundef ) {
    return Qnil;
  }

  if (RTEST(waking)) {
    run_thread(waking);
  }

  return self;
}

static VALUE rb_mutex_synchronize _((VALUE));

static VALUE
rb_mutex_synchronize(self)
  VALUE self;
{
  rb_mutex_lock(self);
  return rb_ensure(rb_yield, Qundef, rb_mutex_unlock, self);
}

typedef struct _ConditionVariable {
  List waiting;
} ConditionVariable;

static void mark_condvar _((ConditionVariable *));

static void
mark_condvar(condvar)
  ConditionVariable *condvar;
{
  mark_list(&condvar->waiting);
}

static void finalize_condvar _((ConditionVariable *));

static void
finalize_condvar(condvar)
  ConditionVariable *condvar;
{
  finalize_list(&condvar->waiting);
}

static void free_condvar _((ConditionVariable *));

static void
free_condvar(condvar)
  ConditionVariable *condvar;
{
  assert_no_survivors(&condvar->waiting, "condition variable", condvar);
  finalize_condvar(condvar);
  free(condvar);
}

static void init_condvar _((ConditionVariable *));

static void
init_condvar(condvar)
  ConditionVariable *condvar;
{
  init_list(&condvar->waiting);
}

static VALUE rb_condvar_alloc _((VALUE));

static VALUE
rb_condvar_alloc(klass)
  VALUE klass;
{
  ConditionVariable *condvar;

  condvar = (ConditionVariable *)malloc(sizeof(ConditionVariable));
  init_condvar(condvar);

  return Data_Wrap_Struct(klass, mark_condvar, free_condvar, condvar);
}

static void wait_condvar _((ConditionVariable *, Mutex *));

static void
wait_condvar(condvar, mutex)
  ConditionVariable *condvar;
  Mutex *mutex;
{
  rb_thread_critical = 1;
  if (!RTEST(mutex->owner)) {
    rb_thread_critical = Qfalse;
    return;
  }
  if ( mutex->owner != rb_thread_current() ) {
    rb_thread_critical = Qfalse;
    rb_raise(private_eThreadError, "Not owner");
  }
  mutex->owner = Qnil;
  push_list(&condvar->waiting, rb_thread_current());
  rb_thread_stop();

  lock_mutex(mutex);
}

static VALUE legacy_exclusive_unlock _((VALUE));

static VALUE
legacy_exclusive_unlock(mutex)
  VALUE mutex;
{
  return rb_funcall(mutex, rb_intern("exclusive_unlock"), 0);
}

typedef struct {
  ConditionVariable *condvar;
  VALUE mutex;
} legacy_wait_args;

static VALUE legacy_wait _((VALUE, legacy_wait_args *));

static VALUE
legacy_wait(unused, args)
  VALUE unused;
  legacy_wait_args *args;
{
  push_list(&args->condvar->waiting, rb_thread_current());
  rb_thread_stop();
  rb_funcall(args->mutex, rb_intern("lock"), 0);
  return Qnil;
}

static VALUE rb_condvar_wait _((VALUE, VALUE));

static VALUE
rb_condvar_wait(self, mutex_v)
  VALUE self;
  VALUE mutex_v;
{
  ConditionVariable *condvar;
  Data_Get_Struct(self, ConditionVariable, condvar);

  if ( CLASS_OF(mutex_v) != rb_cMutex ) {
    /* interoperate with legacy mutex */
    legacy_wait_args args;
    args.condvar = condvar;
    args.mutex = mutex_v;
    rb_iterate(legacy_exclusive_unlock, mutex_v, legacy_wait, (VALUE)&args);
  } else {
    Mutex *mutex;
    Data_Get_Struct(mutex_v, Mutex, mutex);
    wait_condvar(condvar, mutex);
  }

  return self;
}

static VALUE rb_condvar_broadcast _((VALUE));

static VALUE
rb_condvar_broadcast(self)
  VALUE self;
{
  ConditionVariable *condvar;

  Data_Get_Struct(self, ConditionVariable, condvar);
  
  rb_thread_critical = 1;
  rb_ensure(wake_all, (VALUE)&condvar->waiting, set_critical, 0);
  rb_thread_schedule();

  return self;
}

static void signal_condvar _((ConditionVariable *condvar));

static void
signal_condvar(condvar)
  ConditionVariable *condvar;
{
  VALUE waking;
  rb_thread_critical = 1;
  waking = rb_ensure(wake_one, (VALUE)&condvar->waiting, set_critical, 0);
  if (RTEST(waking)) {
    run_thread(waking);
  }
}

static VALUE rb_condvar_signal _((VALUE));

static VALUE
rb_condvar_signal(self)
  VALUE self;
{
  ConditionVariable *condvar;
  Data_Get_Struct(self, ConditionVariable, condvar);
  signal_condvar(condvar);
  return self;
}

typedef struct _Queue {
  Mutex mutex;
  ConditionVariable value_available;
  ConditionVariable space_available;
  List values;
  unsigned long capacity;
} Queue;

static void mark_queue _((Queue *));

static void
mark_queue(queue)
  Queue *queue;
{
  mark_mutex(&queue->mutex);
  mark_condvar(&queue->value_available);
  mark_condvar(&queue->space_available);
  mark_list(&queue->values);
}

static void finalize_queue _((Queue *));

static void
finalize_queue(queue)
  Queue *queue;
{
  finalize_mutex(&queue->mutex);
  finalize_condvar(&queue->value_available);
  finalize_condvar(&queue->space_available);
  finalize_list(&queue->values);
}

static void free_queue _((Queue *));

static void
free_queue(queue)
  Queue *queue;
{
  assert_no_survivors(&queue->mutex.waiting, "queue", queue);
  assert_no_survivors(&queue->space_available.waiting, "queue", queue);
  assert_no_survivors(&queue->value_available.waiting, "queue", queue);
  finalize_queue(queue);
  free(queue);
}

static void init_queue _((Queue *));

static void
init_queue(queue)
  Queue *queue;
{
  init_mutex(&queue->mutex);
  init_condvar(&queue->value_available);
  init_condvar(&queue->space_available);
  init_list(&queue->values);
  queue->capacity = 0;
}

static VALUE rb_queue_alloc _((VALUE));

static VALUE
rb_queue_alloc(klass)
  VALUE klass;
{
  Queue *queue;
  queue = (Queue *)malloc(sizeof(Queue));
  init_queue(queue);
  return Data_Wrap_Struct(klass, mark_queue, free_queue, queue);
}

static VALUE rb_queue_marshal_load _((VALUE, VALUE));

static VALUE
rb_queue_marshal_load(self, data)
  VALUE self;
  VALUE data;
{
  Queue *queue;
  VALUE array;
  Data_Get_Struct(self, Queue, queue);

  array = rb_marshal_load(data);
  if ( TYPE(array) != T_ARRAY ) {
    rb_raise(rb_eRuntimeError, "expected Array of queue data");
  }
  if ( RARRAY(array)->len < 1 ) {
    rb_raise(rb_eRuntimeError, "missing capacity value");
  }
  queue->capacity = NUM2ULONG(rb_ary_shift(array));
  push_multiple_list(&queue->values, RARRAY(array)->ptr, (unsigned)RARRAY(array)->len);

  return self;
}

static VALUE rb_queue_marshal_dump _((VALUE));

static VALUE
rb_queue_marshal_dump(self)
  VALUE self;
{
  Queue *queue;
  VALUE array;
  Data_Get_Struct(self, Queue, queue);

  array = array_from_list(&queue->values);
  rb_ary_unshift(array, ULONG2NUM(queue->capacity));
  return rb_marshal_dump(array, Qnil);
}

static VALUE rb_queue_clear _((VALUE));

static VALUE
rb_queue_clear(self)
  VALUE self;
{
  Queue *queue;
  Data_Get_Struct(self, Queue, queue);

  lock_mutex(&queue->mutex);
  clear_list(&queue->values);
  signal_condvar(&queue->space_available);
  unlock_mutex(&queue->mutex);

  return self;
}

static VALUE rb_queue_empty_p _((VALUE));

static VALUE
rb_queue_empty_p(self)
  VALUE self;
{
  Queue *queue;
  VALUE result;
  Data_Get_Struct(self, Queue, queue);

  lock_mutex(&queue->mutex);
  result = ( ( queue->values.size == 0 ) ? Qtrue : Qfalse );
  unlock_mutex(&queue->mutex);

  return result;
}

static VALUE rb_queue_length _((VALUE));

static VALUE
rb_queue_length(self)
  VALUE self;
{
  Queue *queue;
  VALUE result;
  Data_Get_Struct(self, Queue, queue);

  lock_mutex(&queue->mutex);
  result = ULONG2NUM(queue->values.size);
  unlock_mutex(&queue->mutex);

  return result;
}

static VALUE rb_queue_num_waiting _((VALUE));

static VALUE
rb_queue_num_waiting(self)
  VALUE self;
{
  Queue *queue;
  VALUE result;
  Data_Get_Struct(self, Queue, queue);

  lock_mutex(&queue->mutex);
  result = ULONG2NUM(queue->value_available.waiting.size +
                     queue->space_available.waiting.size);
  unlock_mutex(&queue->mutex);

  return result;
}

static VALUE rb_queue_pop _((int, VALUE *, VALUE));

static VALUE
rb_queue_pop(argc, argv, self)
  int argc;
  VALUE *argv;
  VALUE self;
{
  Queue *queue;
  int should_block;
  VALUE result;
  Data_Get_Struct(self, Queue, queue);

  if ( argc == 0 ) {
    should_block = 1;
  } else if ( argc == 1 ) {
    should_block = !RTEST(argv[0]);
  } else {
    rb_raise(rb_eArgError, "wrong number of arguments (%d for 1)", argc);
  }

  lock_mutex(&queue->mutex);
  if ( !queue->values.entries && !should_block ) {
    unlock_mutex(&queue->mutex);
    rb_raise(private_eThreadError, "queue empty");
  }

  while (!queue->values.entries) {
    wait_condvar(&queue->value_available, &queue->mutex);
  }

  result = shift_list(&queue->values);
  if ( queue->capacity && queue->values.size < queue->capacity ) {
    signal_condvar(&queue->space_available);
  }
  unlock_mutex(&queue->mutex);

  return result;
}

static VALUE rb_queue_push _((VALUE, VALUE));

static VALUE
rb_queue_push(self, value)
  VALUE self;
  VALUE value;
{
  Queue *queue;
  Data_Get_Struct(self, Queue, queue);

  lock_mutex(&queue->mutex);
  while ( queue->capacity && queue->values.size >= queue->capacity ) {
    wait_condvar(&queue->space_available, &queue->mutex);
  }
  push_list(&queue->values, value);
  signal_condvar(&queue->value_available);
  unlock_mutex(&queue->mutex);

  return self;
}

static VALUE rb_sized_queue_max _((VALUE));

static VALUE
rb_sized_queue_max(self)
  VALUE self;
{
  Queue *queue;
  VALUE result;
  Data_Get_Struct(self, Queue, queue);

  lock_mutex(&queue->mutex);
  result = ULONG2NUM(queue->capacity);
  unlock_mutex(&queue->mutex);

  return result;
}

static VALUE rb_sized_queue_max_set _((VALUE, VALUE));

static VALUE
rb_sized_queue_max_set(self, value)
  VALUE self;
  VALUE value;
{
  Queue *queue;
  unsigned long new_capacity;
  unsigned long difference;
  Data_Get_Struct(self, Queue, queue);

  new_capacity = NUM2ULONG(value);

  if ( new_capacity < 1 ) {
    rb_raise(rb_eArgError, "value must be positive");
  }

  lock_mutex(&queue->mutex);
  if ( queue->capacity && new_capacity > queue->capacity ) {
    difference = new_capacity - queue->capacity;
  } else {
    difference = 0;
  }
  queue->capacity = new_capacity;
  for ( ; difference > 0 ; --difference ) {
    signal_condvar(&queue->space_available);
  }
  unlock_mutex(&queue->mutex);

  return self;
}

/* Existing code expects to be able to serialize Mutexes... */

static VALUE dummy_load _((VALUE, VALUE)); 

static VALUE
dummy_load(self, string)
  VALUE self;
  VALUE string;
{
  return Qnil;
}

static VALUE dummy_dump _((VALUE));

static VALUE
dummy_dump(self)
  VALUE self;
{
  return rb_str_new2("");
}

static VALUE setup_classes _((VALUE));

static VALUE setup_classes(unused)
  VALUE unused;
{
  rb_mod_remove_const(rb_cObject, ID2SYM(rb_intern("Mutex")));
  rb_cMutex = rb_define_class("Mutex", rb_cObject);
  rb_define_alloc_func(rb_cMutex, rb_mutex_alloc);
  rb_define_method(rb_cMutex, "marshal_load", dummy_load, 1);
  rb_define_method(rb_cMutex, "marshal_dump", dummy_dump, 0);
  rb_define_method(rb_cMutex, "initialize", return_value, 0);
  rb_define_method(rb_cMutex, "locked?", rb_mutex_locked_p, 0);
  rb_define_method(rb_cMutex, "try_lock", rb_mutex_try_lock, 0);
  rb_define_method(rb_cMutex, "lock", rb_mutex_lock, 0);
  rb_define_method(rb_cMutex, "unlock", rb_mutex_unlock, 0);
  rb_define_method(rb_cMutex, "exclusive_unlock", rb_mutex_exclusive_unlock, 0);
  rb_define_method(rb_cMutex, "synchronize", rb_mutex_synchronize, 0);

  rb_mod_remove_const(rb_cObject, ID2SYM(rb_intern("ConditionVariable")));
  rb_cConditionVariable = rb_define_class("ConditionVariable", rb_cObject);
  rb_define_alloc_func(rb_cConditionVariable, rb_condvar_alloc);
  rb_define_method(rb_cConditionVariable, "marshal_load", dummy_load, 1);
  rb_define_method(rb_cConditionVariable, "marshal_dump", dummy_dump, 0);
  rb_define_method(rb_cConditionVariable, "initialize", return_value, 0);
  rb_define_method(rb_cConditionVariable, "wait", rb_condvar_wait, 1);
  rb_define_method(rb_cConditionVariable, "broadcast", rb_condvar_broadcast, 0);
  rb_define_method(rb_cConditionVariable, "signal", rb_condvar_signal, 0);

  rb_mod_remove_const(rb_cObject, ID2SYM(rb_intern("Queue")));
  rb_cQueue = rb_define_class("Queue", rb_cObject);
  rb_define_alloc_func(rb_cQueue, rb_queue_alloc);
  rb_define_method(rb_cQueue, "marshal_load", rb_queue_marshal_load, 1);
  rb_define_method(rb_cQueue, "marshal_dump", rb_queue_marshal_dump, 0);
  rb_define_method(rb_cQueue, "initialize", return_value, 0);
  rb_define_method(rb_cQueue, "clear", rb_queue_clear, 0);
  rb_define_method(rb_cQueue, "empty?", rb_queue_empty_p, 0);
  rb_define_method(rb_cQueue, "length", rb_queue_length, 0);
  rb_define_method(rb_cQueue, "num_waiting", rb_queue_num_waiting, 0);
  rb_define_method(rb_cQueue, "pop", rb_queue_pop, -1);
  rb_define_method(rb_cQueue, "push", rb_queue_push, 1);
  rb_alias(rb_cQueue, rb_intern("<<"), rb_intern("push"));
  rb_alias(rb_cQueue, rb_intern("deq"), rb_intern("pop"));
  rb_alias(rb_cQueue, rb_intern("shift"), rb_intern("pop"));
  rb_alias(rb_cQueue, rb_intern("size"), rb_intern("length"));

  rb_mod_remove_const(rb_cObject, ID2SYM(rb_intern("SizedQueue")));
  rb_cSizedQueue = rb_define_class("SizedQueue", rb_cQueue);
  rb_define_method(rb_cSizedQueue, "initialize", rb_sized_queue_max_set, 1);
  rb_define_method(rb_cSizedQueue, "clear", rb_queue_clear, 0);
  rb_define_method(rb_cSizedQueue, "empty?", rb_queue_empty_p, 0);
  rb_define_method(rb_cSizedQueue, "length", rb_queue_length, 0);
  rb_define_method(rb_cSizedQueue, "num_waiting", rb_queue_num_waiting, 0);
  rb_define_method(rb_cSizedQueue, "pop", rb_queue_pop, -1);
  rb_define_method(rb_cSizedQueue, "push", rb_queue_push, 1);
  rb_define_method(rb_cSizedQueue, "max", rb_sized_queue_max, 0);
  rb_define_method(rb_cSizedQueue, "max=", rb_sized_queue_max_set, 1);
  rb_alias(rb_cSizedQueue, rb_intern("<<"), rb_intern("push"));
  rb_alias(rb_cSizedQueue, rb_intern("deq"), rb_intern("pop"));
  rb_alias(rb_cSizedQueue, rb_intern("shift"), rb_intern("pop"));

  return Qnil;
}

void
Init_fastthread()
{
  int saved_critical;

  avoid_mem_pools = rb_gv_get("$fastthread_avoid_mem_pools");
  rb_global_variable(&avoid_mem_pools);
  rb_define_variable("$fastthread_avoid_mem_pools", &avoid_mem_pools);

  rb_require("thread");

  private_eThreadError = rb_const_get(rb_cObject, rb_intern("ThreadError"));

  /* ensure that classes get replaced atomically */
  saved_critical = rb_thread_critical;
  rb_thread_critical = 1;
  rb_ensure(setup_classes, Qnil, set_critical, (VALUE)saved_critical);
}

